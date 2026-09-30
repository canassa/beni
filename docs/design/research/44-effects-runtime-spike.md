# The fiber runtime spike, measured

**Commissioned by** the owner's 2026-09-30 decisions on the effects plan: build step 3, the runtime
spike — a fiber runtime and the lowering of every function whose inferred bit is `suspends`, with
`spawn`, `join`, `scope` and `bracket` and one platform primitive — and measure it against
Effect v4, the gold standard for effects, in Node and in headless Chrome, browser first.

**The contract** is [`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §16
(**P2 §16** below), written before the code and amended by its *As built* note. This report holds
what the spike measured and what the numbers mean for the adoption; it specifies nothing.

**Machine.** AMD Ryzen 9 5950X (16 cores, 32 threads), Linux 6.12, load average under 0.2 for every
run. Node v24.19.0; Chrome 153.0.8010.36 headless (`nix develop .#browser`), launched with
`bench/ui/lib/cdp.mjs`'s flags (background timer throttling off). Effect `4.0.0-rc.116`, the
version `references/effect` is checked out at, bundled for the page with esbuild 0.25.10.
Every timing is the median of 9 runs after 3 warm-up runs.

---

## 0. Findings

1. **Code that does not suspend did not move by one byte.** Every `emit/` golden and every
   `run/` hash of the tree before the spike is unchanged; the only goldens that changed are the
   two the spike added and one test's graph that now lists `core:Task`. Pure and impure code is
   emitted exactly as before, because every decision is keyed on a class that reaches `suspends`
   or depends on one that may (P2 §16, *What must not move*). The cache cutoff test's counts of
   modules cut off grew by one, the new `core` module.
2. **A suspension point on its fast path costs one comparison, and that is what it costs.** In a
   tail-call loop, a call that may suspend and does not is **2.41 ns** against a plain call's
   **1.66 ns** in Node (+45%), and **6.46 ns** against **1.82 ns** in Chrome. Outside a loop, where
   each point hands the rest of the function to `Task.andThen` as a closure, it is **2.03 ns** in
   Node and **4.97 ns** in Chrome. Effect's nearest equivalent, one synchronous operation chained
   by `flatMap`, is **97.8 ns** in Node and **60.0 ns** in Chrome: beni's fast path is **12–48×**
   cheaper, because there is no interpreter step to pay — the call is a call.
3. **A real park is 12× cheaper than Effect's in Node and ~25 000× in a browser.** `yieldNow` in a
   loop is **124.5 ns** per yield in Node (Effect: **1 527 ns**) and **162.3 ns** in Chrome.
   Effect's `yieldNow` in Chrome is **4.13 ms** per yield: its scheduler parks on `setImmediate`
   where the host has it and on `setTimeout(0)` where it does not — every browser — and a browser
   clamps a nested `setTimeout` to 4 ms. beni's runtime escapes to a `MessageChannel` macrotask in
   a browser, which is not clamped (§3).
4. **10 000 fibers fan out and join in 3.4 ms in Node and 3.8 ms in Chrome** (343 and 377 ns per
   fiber, each spawned, yielding once, joined in order and summed). Effect: 9.5 ms and 70.3 ms.
5. **The whole runtime is 2 kB brotli in a release application; Effect's is 27 kB.** A program
   using a scope, a bracket, a spawn, a join and a timer is 6 313 bytes raw and **2 114** brotli as
   one scope-hoisted `--release` file, against **162** for the same program without waiting — so
   the runtime and the program's continuations cost **1 952** bytes brotli. The same program in
   Effect v4, bundled and minified by esbuild with tree shaking, is 86 130 raw and **26 878**
   brotli: **12.7×** (§4).
6. **The yield budget of 64 is the right order for a browser.** At 64 resumptions per microtask
   drain, a 200 000-yield loop in Chrome takes 30.1 ms and never delays a frame by more than one
   (longest gap 16.6 ms, a `setTimeout(0)` fires after 0.1 ms). At 512 it takes 13.9 ms with one
   13.2 ms gap; at 2 048 it takes 13.5 ms and holds the page for all of it. 64 costs 2.2× the
   throughput of 512 on a loop that does nothing but yield, and nothing on code that does not
   yield, since the budget counts resumptions, never calls (§3).
7. **The checker's new work is small.** Building a trivial `node` program went from 210.9 M to
   213.6 M instructions (+1.3%); checking one with no platform, which checks the grown `core/`
   whole, from 148.1 M to 158.1 M (+6.8%, of which the new `Task` module is most). Every gated test
   stays under the 4 300 M-instruction budget, two after changes described in §6.

---

## 1. What was built

- **The checker's answers.** After the effect solve, `src/check/EffectPlan.zig` answers, per call,
  per function and per reference to a two-bodied declaration, **no**, **yes** or **poly** (P2
  §16.2), and marks the declarations whose scheme has a *sensitive* class — one below `suspends`
  that reaches something the lowering reads. The answers ride in the dispatch sidecar (format 7);
  the sensitive bit rides in the interface (format 11).
- **The lowering** (`src/js/Lower.zig`, `src/js/Suspend.zig`): a call that may suspend is hoisted
  like `?`, and a post-pass turns each hoist into either a closure continuation or, in a tail-call
  loop, a fast path that stays in the loop. Joins for a `case`, `&&` and `||` whose branches may
  suspend. A declaration with a sensitive class gets a second body, `<name>$s`, emitted only when
  something reaches it.
- **The runtime**, `core/Task.js` (13 kB of commented source) under `core/Task.beni`: the sentinel,
  the fiber record, a FIFO scheduler drained in a microtask with a macrotask escape every 64
  resumptions, interruption (at once for a parked fiber, latched and delivered at the next
  suspension point otherwise), finalisers run last first, scopes. `scope`, `bracket` and
  `uninterruptible` are beni.
- **The platform primitive**: the `node` platform's new module `Io` — `Io.run`, `Io.sleep` over a
  timer and `Io.readFile` over a promise, cancelled through an `AbortSignal`.
- **The release optimiser keeps `let _ = <impure call>`**, the one place where dropping an unread
  binding would drop an effect a spike program depends on (`let _ = Task.spawnIn s work`).

### The lowered shapes

From `tests/corpus/emit/SuspendShapes.js`, development build:

```js
// fetch n = let _ = Io.sleep n in n + 1
const SuspendShapes$fetch = (n$1) => Task$andThen(Io$sleep(n$1), ($t$1) => Basics$add(n$1, 1));

// twice f x = f (f x), called with a pure and with a suspending `f`: two bodies
const SuspendShapes$twice = (f$1, x$2) => f$1(f$1(x$2));
const SuspendShapes$twice$s = (f$1, x$2) => Task$andThen(f$1(x$2), ($t$6) => f$1($t$6));
```

and inside a tail-call loop, the fast path continues in place and only the slow path allocates:

```js
const $t$5 = SuspendShapes$fetch(x$3);
if (Task$isWaiting($t$5)) {
  return Task$andThen($t$5, ($t$5) => {
    $in$0 = rest$4;
    $in$1 = Basics$add(acc$2, $t$5);
    return SuspendShapes$total($in$0, $in$1);
  });
}
$in$0 = rest$4;
$in$1 = Basics$add(acc$2, $t$5);
continue SuspendShapes$total;
```

The continuation of a loop is the rest of the iteration with every `continue` turned into a call of
the function with its slots, which is the plan's finding that the loop's state *is* its parameter
list.

---

## 2. The fast path

| Workload (Node v24.19.0) | ops | median | per op |
|---|---:|---:|---:|
| beni: plain call, in a tail-call loop | 10 000 000 | 16.6 ms | **1.66 ns** |
| beni: call that may suspend, fast path, in a tail-call loop | 10 000 000 | 24.1 ms | **2.41 ns** |
| beni: four such calls in sequence (closure continuations) | 10 000 000 | 20.3 ms | **2.03 ns** |
| Effect v4: `Effect.sync` chained by `flatMap`, `runSync` | 1 000 000 | 97.8 ms | 97.8 ns |
| Effect v4: `Effect.sync` in `Effect.gen`, `runSync` | 1 000 000 | 97.0 ms | 97.0 ns |

| Workload (Chrome 153 headless) | ops | median | per op |
|---|---:|---:|---:|
| beni: plain call, in a tail-call loop | 10 000 000 | 18.2 ms | **1.82 ns** |
| beni: call that may suspend, fast path, in a tail-call loop | 10 000 000 | 64.6 ms | **6.46 ns** |
| beni: four such calls in sequence (closure continuations) | 10 000 000 | 49.7 ms | **4.97 ns** |
| Effect v4: `Effect.sync` chained by `flatMap`, `runSync` | 1 000 000 | 60.0 ms | 60.0 ns |
| Effect v4: `Effect.sync` in `Effect.gen`, `runSync` | 1 000 000 | 60.4 ms | 60.4 ns |

The sequence is cheaper per call than the loop although it writes a closure per point; the likely
reason is that V8 inlines the small `Task.andThen` and the continuation, so the closure never
escapes, but this was not confirmed with a profile. The loop pays a comparison and a branch per iteration that its plain twin does not, and Chrome's
V8 does visibly less with it than Node's; the cause was not chased, because the answer the spike
needed does not depend on it — both are an order of magnitude under Effect's step, and neither
allocates.

The comparison is not like for like, and cannot be: Effect's program is a data structure an
interpreter walks, and the per-operation cost is that walk. What the numbers say is that the
design of P2 §7 — a function that may suspend is a function, and its fast path is a call — holds
when built.

## 3. Parking, fan-out and the budget

| Workload | Node | Chrome |
|---|---:|---:|
| beni: `yieldNow`, per yield (1 000 000) | **124.5 ns** | **162.3 ns** |
| Effect v4: `yieldNow`, per yield | 1 527 ns (1 000 000) | **4 130 000 ns** (1 000) |
| beni: 10 000 fibers spawned, yield once, joined | **3.43 ms** | **3.77 ms** |
| Effect v4: 10 000 fibers `forkChild`, yield once, joined | 9.53 ms | 70.3 ms |

Effect's page count is 1 000 yields rather than 1 000 000 because each takes 4 ms: its
`MixedScheduler` (`effect/dist/Scheduler.js`, `setTimer`) uses `setImmediate` when the global
exists and `setTimeout(f, 0)` otherwise, and the HTML standard clamps a timer nested five deep to
4 ms. A browser Effect program that yields — which its fibers do after 2 048 operations by default
— waits 4 ms each time. beni's runtime picks `setImmediate` or a `MessageChannel`, never a timer.

**The budget sweep.** The same build with the runtime's `const budget` patched
(`bench/fiber/budgets.mjs`); a 200 000-yield loop, with a `setTimeout(0)` armed as it starts and,
in Chrome, `requestAnimationFrame` asked for every frame of it.

| Budget | Node: loop | Node: timer after | Chrome: loop | Chrome: timer after | frames | longest frame gap |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 35.9 ms | 1.0 ms | 88.9 ms | 0.1 ms | 7 | 16.7 ms |
| **64** | **23.2 ms** | 0.8 ms | **30.1 ms** | 0.1 ms | 2 | **16.6 ms** |
| 512 | 18.7 ms | 0.6 ms | 13.9 ms | 0.1 ms | 1 | 13.2 ms |
| 2 048 | 19.8 ms | 1.2 ms | 13.5 ms | 0.4 ms | 0 | (no frame) |
| Effect v4 | 323.3 ms | 0.5 ms | 4 099 ms (1 000 yields) | 4.1 ms | 247 | 17.0 ms |

A budget buys a frame's worth of fairness, not throughput: at 64 the page paints on time through a
loop of pure yields, at 2 048 it does not paint at all until the loop ends. The spike keeps 64,
P2 §7.5's choice. A loop that does work between yields takes more time per resumption, so the
budget's cost falls as the work grows; one that does not yield at all is never pre-empted, which
is the same answer as Effect's and the reason both need a `yieldNow` a programmer can write.

## 4. Bytes

`bench/fiber/size.mjs`: `beni build --release --platform=node` of `apps/Plain.beni` and
`apps/Fibers.beni`, one scope-hoisted `_main.mjs` each; `apps/effect-fibers.mjs` bundled by esbuild
with `--minify`, tree shaking on, for the browser.

| Program | raw | gzip -9 | brotli 11 |
|---|---:|---:|---:|
| beni: `Plain` — prints `worker 21` | 233 | 186 | 162 |
| beni: `Fibers` — a scope, a bracket, a spawn into it, a join, a sleep | 6 313 | 2 297 | **2 114** |
| Effect v4: the same program | 86 130 | 29 919 | **26 878** |

The difference between the first two rows, **1 952 bytes brotli**, is the whole fiber runtime plus
the program's continuations: the release optimiser's renaming and `--release`'s compaction of
hand-written JavaScript apply to `Task.js` like any sibling. The runtime ships whole: its exports
are few and call each other, so elimination has little to cut, and a program that does not wait
reaches none of it — `Plain` ships no byte of `Task`.

## 5. Correctness, and how it was shown

`tests/corpus/run/`, each written red first, each built and run twice (development and `--release`)
by the gates:

| Fixture | What it pins |
|---|---|
| `SuspendSequence` | `Debug.log` order across the fast and the slow path |
| `SpawnJoin` | three children wake in timer order; `join` answers in spawn order, at once for a child already ended |
| `ScopeChildren` | a scope ending with a child still running cancels it and awaits its cleanup; a `spawn` child is cancelled with its parent |
| `BracketRelease` | release exactly once, with the outcome: on success, on outside cancellation mid-wait (timer cleared, inner before outer), on joining a cancelled fiber |
| `SuspendDeepRecursion` | 200 000-deep non-tail recursion that parks at every level, which unsuspended would overflow the stack |
| `SuspendLoopFastPath` | 1 000 000 steps through a suspending callback on the fast path |
| `SuspendBothWays` | `List.map` with a pure and with a suspending callback in one program |
| `SuspendJoinPoint` | a `case`, an `if` and a short-circuiting `&&` whose branches suspend; a join inside a loop |
| `SuspendLoopClosure` | a continuation that closes over a loop iteration's values |
| `SuspendReadFile` | the promise-backed primitive: parks, another fiber runs meanwhile, resumes with `Err` |

`emit/SuspendShapes` and `emit/release/SuspendShapes` pin the lowered shapes quoted in §1.
`check/bad/core/TopLevelValueSuspends` pins the decision taken first: a top-level value other than
a function must not suspend.

## 6. What building it found

- **A top-level value can suspend, and must not.** It is evaluated once, when its module loads,
  where nothing can wait for it; the checker already refused `main`'s. The rule now covers every
  parameterless declaration (P2 §15.6), and the one corpus test that used a suspending value
  (`check/bad/core/SyncEvidence`) now uses functions of `()`.
- **`await` is a reserved word in an ES module**, so the primitive that observes a fiber's exit is
  `wait`.
- **`let _ = e` needed a keep rule in the release optimiser.** Development output was right; the
  release build dropped `let _ = Task.spawnIn s work` as a dead binding, and the fixtures' two
  builds disagreed. The table's `impure` answer, which the checker already had, is what keeps it.
- **Two tests went over the instruction budget** when `core/` grew by the `Task` module and the
  sensitivity analysis ran over it. Both were fixed without an exemption: the analysis now skips a
  class marked `sync` (it cannot suspend, so it is never sensitive), and the sibling export check
  stopped re-reading a sibling once per export (`⚡` commit).

## 7. Reproduce

```sh
cd bench/fiber && npm install          # effect 4.0.0-rc.116, esbuild 0.25.10
zig build                              # ./zig-out/bin/beni
beni build --library --platform=node --out=out/dev Bench.beni
node budgets.mjs out/dev out 16 64 512 2048
node node.mjs out/dev 16=out/b16 64=out/b64 512=out/b512 2048=out/b2048
nix develop .#browser -c node chrome.mjs out/dev 16=out/b16 64=out/b64 512=out/b512 2048=out/b2048
node size.mjs ../../zig-out/bin/beni out/size
```

`FIBER_SIZES='{"calls":…,"effectYields":…}'` shrinks the page's counts for a quick run.

## 8. What the spike leaves for the adoption

- **The other eleven primitives** of P2 §6.5 (decision 3), and a browser primitive: the browser
  platform gains a suspending operation with The Elm Architecture's commands, whose type is the
  browser decisions' to take. No page fixture exists yet for that reason; the runtime runs in a
  page only here.
- **A per-site choice of body for evidence.** A declaration passed as `where` evidence takes the
  body its site's callee takes; erring towards `$s` costs speed, never correctness.
- **Mutual recursion on the fast path** keeps a real frame per call, as it did before.
- **Tail recursion modulo cons is off in a suspendable body** (P2 §16.3), so a `::`-building
  recursion that may suspend uses a frame per element on the fast path. *(Closed 2026-09-30: a
  suspendable body builds too, its slow path linking a re-entry's list into `$last` — `backend.md`
  §8, *What it owes the fiber lowering*.)*
- **A named binding nothing reads is still dropped by `--release`**, even over an impure call; only
  `let _ =` is kept. *(Closed 2026-09-30: every binding that may be impure is kept — `backend.md`
  §9 item 1, `language.md` §6.)*
- **A join allocates its closure** even when no branch parks; a join in a loop is inlined into each
  leaf instead, so the hot case does not.
- **Source maps and logical stack traces** (P2 §7.4) are M5's.
