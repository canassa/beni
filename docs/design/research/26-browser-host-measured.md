# The browser as a host for beni's runtime, measured

**Commissioned by** the project owner's 2026-09-19 decision recorded in
[`CLAUDE.md`](../../../CLAUDE.md)'s Target bullet — ***"Beni is primarily a browser language, and
the browser platform comes before Node… weigh every design choice — the fiber runtime's scheduler,
output size, chunking, source maps, what `main` is — by what it does in a browser first"*** — and by
[`research/21`](21-effect-v4-runtime.md) §0.5 item 1, *"the browser latency histogram… still
unrun"*, and [`plans/effects-spike.md`](../../../plans/effects-spike.md) E-M10, whose browser half
this report takes early.

**What this is.** Measurements, in two browser engines, of the things a fiber runtime and a UI
platform have to sit on: the primitives a fiber can yield through, what a yield budget buys, what
must run synchronously, what cancellation costs, what a defect does to a page, what the emitted
module tree costs to load, and what a browser test kind costs per fixture.

**What this is not.** It is not a UI architecture argument — that is report 25 — and it is not a
reading of Elm's runtime — that is report 24. Where this report needs a fact about Elm it says so
and defers. It is also not a design document: §11 hands the owner numbered questions, with a
recommendation each, and takes no decisions.

**Citations.** `e1.js`, `e2c-slice.mjs` … are the scripts, all reproduced inline and all left in the
scratchpad. `P2` is [`transparent-effects-proposal.md`](../transparent-effects-proposal.md), `R21` is
[`research/21`](21-effect-v4-runtime.md), `R16` is
[`research/16`](16-fibers-and-concurrency.md), `R12` is
[`research/12`](12-js-output-and-chunking.md). Web platform citations are to the WHATWG HTML
standard, the W3C/WICG drafts and MDN, by URL, in §13.

**Read §0, then §11.** §0 is the one-page answer; §11 is the owner's question list. §1–§10 are the
evidence.

**One engine, unless stated.** Every number is Chrome unless a Firefox column sits beside it. Chrome
is `--headless=new`; §1.4 states exactly what that changes and which numbers depend on it.

---

## 0. Findings

### 0.1 The recommended default browser scheduler

**Yield through `MessageChannel`, on a time slice of ~1 ms enforced by a hybrid counter, and do not
copy Node's 512.**

| | the number | where |
|---|---|---|
| **the primitive** | `MessageChannel.postMessage` — **3.8 µs/hop** Chrome, **2.0 µs/hop** Firefox, unclamped, universally supported, and the only fast macrotask that no other task priority can starve | §2.1, §2.4 |
| **the budget** | a **time slice**, not an op count. At a 465 ns work unit, input latency p90 tracks the slice almost exactly: 0.24 ms slice → p90 **1 ms**; 7.8 ms → **5 ms**; 31 ms → **26 ms**; 125 ms → **102 ms** and the first long task | §3.3 |
| **what it costs** | a slice of **0.24 ms** already puts the yield overhead at **1.01×**, and ≥0.5 ms at **1.00×**. There is no throughput reason to run a slice longer than about 1 ms | §3.4 |
| **how to enforce it** | count `k` ops, then read `Date.now()` — 33 ns in Chrome, 50 ns in Firefox, against 166 ns for `performance.now()`, which is *also* clamped to 100 µs in Chrome and **1 ms in Firefox** | §2.5 |

The three numbers that justify it:

1. **A microtask yield is worse than no yield at all.** A fiber that yields through
   `queueMicrotask` every 64 ops has an input-handler delay of **p50 371 ms, max 653 ms** — against
   **p50 84 ms, max 364 ms** for the same fiber that never yields, and **p50 0 ms, max 1 ms** for
   the same fiber yielding through `MessageChannel` at *any* budget from 16 to 8 192 (§3.2). The
   microtask loop pays the yield cost and buys nothing, because a microtask checkpoint never
   reaches input, timers or rendering (§2.3).
2. **A macrotask yield costs 2–4 µs, so a 1 ms slice costs 0.3 %.** Measured against an interleaved
   no-yield baseline, min of 7, in both engines (§3.4).
3. **`isInputPending` buys a 45× cut in yield count at identical input latency — and a dropped
   frame.** 37 yields against 1 651 for a 512-op budget, both at input p90 = 1 ms; but with no time
   cap it produced an **82 ms long task**. Capped at 5 ms it is the best rule measured on every
   axis (§4.2). It does not exist in Firefox (§4.3).

**What stays Node-specific.** R21 §9.3's **512** is a `setImmediate` number and does not transfer:
`setImmediate` does not exist in any browser (§2.1, confirmed in both engines), and an op count is a
proxy for a time slice with a per-program constant — the same 512 spans **5.6 µs** at an 11 ns op
and **240 µs** at a 465 ns op (§3.1, §3.3). P2 §7.5's **64** is also wrong for a browser, but not
for the reason P2 gives: 64 is harmless on latency and merely wasteful, and P2's premise — that
microtasks are the throughput path and the macrotask is an escape — is the part measurement
contradicts. There is no throughput case for microtasks here at all (§3.4: microtask yielding at
budget 256 and above is 1.00×–1.02×, identical to `MessageChannel`, while being catastrophic for
latency).

**`scheduler.postTask` and `scheduler.yield` are not the default**, on two measured grounds. At
`user-blocking` priority, a fiber starves `setTimeout` and `MessageChannel` completely — an armed
timer fired at **282 ms** in a 275 ms run (§3.1) — and `scheduler.yield()` does the same at
**175 ms** in a 175 ms run, because a yielded continuation is prioritised ahead of same-priority
tasks. At `user-visible` they behave like `MessageChannel` and cost slightly more per hop. Both are
worth having as *alternative scheduler slots* (the owner's A7 decision makes the scheduler
swappable), and `TaskController` gives a canceller for free (§6.3).

### 0.2 The browser callbacks that must be `sync`

Measured, in Chrome, by hopping the handler through each primitive and observing the default action
(§5.1–§5.3). **A microtask hop is still inside the handler's synchronous extent; a macrotask hop is
not.**

| callback | must be `sync`? | what breaks after one macrotask hop |
|---|---|---|
| a `click` on a link / a `submit` on a form | **yes** | `preventDefault()` is too late: the page navigated (`#HASH` set; `/landed.html` loaded) even though `event.defaultPrevented` reads `true` |
| any listener that calls `stopPropagation` | **yes** | the ancestor's listener already ran |
| `beforeunload` | **yes** | not measurable headless (§12); the spec gives it no asynchronous extent at all |
| a `touchmove`/`wheel` listener that calls `preventDefault` | **yes** | not measurable headless (§12); same mechanism as `click`, plus the passive-by-default rule |
| a `requestAnimationFrame` callback | **yes, if its writes are for *this* frame** | a `MessageChannel` hop inside a rAF callback resumed **10.1 ms** later and the write landed in the **next** frame (§5.4) |
| DOM reads and writes in one pass | **yes, and batched** | interleaved read/write over 3 000 nodes: **2 846 ms**, batched read-then-write: **2.5 ms** — **1 139×** (§5.5) |
| anything needing **transient user activation** (`window.open`, fullscreen, `<input type=file>.click()`) | **no** — this one is the surprise | activation **survives macrotask hops for ~5 s**: `window.open` succeeded after a 4 900 ms hop and failed after 5 200 ms (§5.3). Chrome's transient activation duration is 5 s and the HTML spec makes the duration implementation-defined |

So `sync` has to cover event listeners and rAF callbacks, and the platform's answer for a handler
that *wants* to do async work is the one P2 already has: the `sync` handler does the cancelling and
the stopping, then **spawns a fiber** and returns. That is the whole shape, and it is not
negotiable for `preventDefault`.

### 0.3 Cancellation: R21's 57-vs-301 holds, almost to the millisecond

The R21 §4.4 experiment, ported verbatim (a 300 ms uncooperative promise, cancelled at 50 ms). The
two trials run back to back on one clock, so the native trial's own start is at 50 ms:

```
   0ms owned:  parked
  50ms owned:  cancelling
  50ms owned:  continuation resumed with Cancelled     <- unwound 50 ms after ITS start
  50ms native: awaiting                                 <- the native trial starts here
 100ms native: abort()
 351ms native: await returned                           <- unwound 301 ms after ITS start
```

**50 ms against 301 ms in Chrome**, against R21's **57 against 301** on Node. The native figure is
identical to three digits — it is `300 ms` of promise plus scheduling, and `AbortController` never
had any power over it. The lowering decision of 2026-09-15 is confirmed a third time, now in a
browser.

`fetch` + `AbortController` is a genuinely abortable primitive and behaves well: the promise rejects
**0–1.5 ms** after `abort()`, and the server sees the socket close at **51 ms** and **53 ms** — the
connection really closes, mid-body as well as before headers (§6.2). So a beni `Http.get` parked on
`fetch` needs no trick; the 301 ms number is what a runtime pays for primitives that have *no*
abort, which in a browser is most of them (timers, `postMessage` round trips, `IndexedDB` requests,
user-supplied promises).

### 0.4 What "fatal" can mean in a page

The owner decided defects are fatal (A1). **A browser gives you nothing to be fatal with.** Measured
identically in Chrome and Firefox (§7.1): an uncaught throw inside a `MessageChannel` task, a rAF
callback, an event listener, a microtask or a timer kills nothing — the next task runs, the next
frame runs, sibling listeners on the same event still run, the event still bubbles, pending timers
still fire, the DOM is still mutable. `window.onerror` sees it, and that is all. A stack overflow is
a catchable `RangeError` (Chrome) / `InternalError` (Firefox).

So "fatal" in a page is a thing the platform must *implement*, not a thing it can inherit. §7.2 lists
five options with what each costs. This report takes no position; §11 Q6 hands it over.

### 0.5 Loading: the single-file bundle is worth three times what its size says

`tests/corpus/run/Dictionaries.beni` built with `--release --platform=node` is **13 files, 21 322
raw bytes**. Time from navigation to `main` executed, brotli served precompressed, median of 5,
CDP `Network.emulateNetworkConditions` (§8.2):

| network | 13 modules | one bundle | 13 modules + `modulepreload` |
|---|---:|---:|---:|
| unthrottled localhost | 26 ms | **14 ms** | 25 ms |
| 4G, 9 Mbps, 170 ms RTT | 1 059 ms | **358 ms** | 705 ms |
| fast 3G, 1.6 Mbps, 562 ms RTT | 3 437 ms | **1 156 ms** | 2 282 ms |

**3.0× on 4G and 3.0× on fast 3G.** The cause is round-trip depth, not bytes: the module graph is
four levels deep, so the browser cannot even *discover* `core/Dict.mjs` until `Main.mjs` has landed.
`modulepreload` flattens the discovery but not the connection count, and recovers a third of the gap.

The size half of the story is worth separating, because it is bigger than R12's −22 %:

| shape | raw | brotli |
|---|---:|---:|
| 13 files, compressed individually (what a server actually sends) | 21 322 | 7 538 |
| the same 13 files concatenated, then compressed (window effect only) | 21 322 | 6 380 (−15.4 %) |
| a real bundle — module boilerplate and comments gone | **16 102** | **3 269 (−56.6 %)** |

**42 % of the raw bytes of that tree are comments**, and **71.6 % of them are the never-minified
sibling `.foreign.mjs` files**. The bundle's win is mostly *not* the compression window; it is that
bundling is the first thing in the pipeline that touches the sibling JavaScript at all
([`plans/state-of-the-compiler.md`](../../../plans/state-of-the-compiler.md)'s "44–76 %" observation,
measured here at 71.6 %).

### 0.6 The test harness: one warm Chrome, a fresh target per fixture, 10–18 ms

| approach | per fixture | fidelity |
|---|---:|---|
| a Chrome process per fixture | **272 ms** | full |
| one Chrome, a fresh target per fixture | **18.5 ms** | full |
| the same, 8 targets in flight | **10.0 ms** | full |
| `jsdom` in a fresh node process | **511 ms** | no `requestAnimationFrame`, no `MessageChannel` |
| `happy-dom` in a fresh node process | **235 ms** | has rAF, **no `MessageChannel`** |
| a plain node process (the DOM-free core) | **26 ms** | scheduler/fibers/TEA/vdom diff only |

The DOM emulators are **13× to 28× more expensive per fixture than a warm Chrome target and have
worse fidelity** — and the one primitive `happy-dom` is missing is the exact primitive §0.1
recommends the scheduler be built on. There is no case for them here.

At 10 ms per fixture and 8-way parallelism, **125 browser fixtures cost ~1.3 s** against today's
`zig build test-blackbox` of **1 m 50 s** for 668 fixtures (§9.4). A browser kind does not double
the gate; it adds ~2 %.

**Virtual time is free and exact.** CDP `Emulation.setVirtualTimePolicy` ran **five chained 10-second
timers — 50 000 ms of virtual time — in 0.9 ms of real time** (§9.3). For debounce/timeout/animation
fixtures that is a better answer than beni's own swappable clock slot *for the corpus*, because it
needs no cooperation from the program under test; the swappable clock is still what a beni-level
unit test wants. Both, for different jobs.

### 0.7 What depends on headless, and what depends on Chrome

- **rAF cadence is real.** `--headless=new` runs `requestAnimationFrame` at a genuine 60 Hz
  (16.7 ms median, min 16.6, max 16.8 over 29 frames) and the cadence **does** stretch under load
  (18.6 ms of work per frame → 21.7 ms wall delta; 55.8 ms → 65.1 ms). There is no display and no
  real vsync, so frame *jitter* and compositor behaviour are not represented; frame *budget* numbers
  are (§1.4, §5.6).
- **`requestIdleCallback`'s period is a headless artefact**: 50 ms in Chrome, 98 ms in Firefox, both
  at the "no pending work, fall back to the maximum idle period" path. Do not read it as the number
  a real tab gives.
- **Chrome-only APIs**: `navigator.scheduling.isInputPending` (absent in Firefox 156) and the
  `longtask` PerformanceObserver entry type (absent in Firefox 156, which also lacks
  `long-animation-frame`). `scheduler.postTask`, `scheduler.yield` and `TaskController` are present
  in **both** Chrome 153 and Firefox 156 (§2.2).
- **Not measurable here**: clipboard and fullscreen activation gating, `beforeunload`, passive
  `touchmove`, real compositor/vsync, and anything about Safari (§12).

---

## 1. Method

### 1.1 What was driven, and how

Three harnesses, all in the scratchpad, none of them needing an npm dependency to *drive* a browser:

1. **CDP over Node 24's built-in `WebSocket`** — `harness.mjs`, 40 lines. This is what almost
   everything uses, because `Input.dispatchMouseEvent`, `Network.emulateNetworkConditions` and
   `Emulation.setVirtualTimePolicy` have no substitute. `launch()` spawns Chrome, polls
   `/json/version`, connects to the browser target, and `newPage()` uses `Target.createTarget` +
   `Target.attachToTarget {flatten:true}` so several page targets can share one browser socket.
2. **A POST-back page** — `postsrv.mjs` + `xengine.mjs`, 25 lines. The page runs the measurement
   script and `fetch`es the JSON result back to the local server. **This needs no devtools protocol
   at all**, which is how the Firefox columns exist: Firefox's CDP surface is deprecated in favour of
   WebDriver BiDi and was not worth the time (the task's "try once, do not sink time into it").
3. **A throwaway static server** — `serve.mjs` / `loadsrv.mjs`, the latter serving brotli
   precompressed with `content-encoding: br` when the client accepts it. Everything is served from
   `http://localhost`, which is a secure context.

Option (c) from the brief — `--dump-dom` / `--virtual-time-budget` — was not used: every experiment
here needs either injected input, network emulation or a multi-step protocol conversation.
`puppeteer-core` was not installed; the 40-line CDP client was enough and keeps the evidence
readable.

### 1.2 Versions, flags, machine

| | |
|---|---|
| Chrome | **153.0.8010.47**, V8 **15.3.76.12**, `HeadlessChrome/153.0.0.0` |
| Chrome flags | `--headless=new --remote-debugging-port=N --user-data-dir=<tmp> --no-first-run --no-default-browser-check --disable-gpu --disable-dev-shm-usage --no-sandbox` |
| Firefox | **156.0** (`rv:156.0`), obtained with `nix run nixpkgs#firefox`, flags `--headless --profile <tmp> --no-remote <url>` |
| Node | **v24.19.0** |
| machine | Ryzen 9 5950X (16c/32t), Linux 6.12.110 |
| `crossOriginIsolated` | **false** in both engines — see §2.5, it sets the clock resolution |

**Load.** Unlike R21, the machine was quiet. `uptime` 1-minute load average at the start of each
batch: §2 **0.07**, §3 sweep **0.08**, §3 input **0.12**, §3 slice **0.16**, §4 **0.39** (rising to
0.55 — the §4 throughput column is contaminated and says so), §6 **0.09**, §8 **0.23**, §9 **0.39**.
Where a table's absolute throughput matters it is min-of-N with an interleaved baseline (§3.4).

### 1.3 The fiber micro-kernel

Effect was **not** installed. R21 established what the kernel is; porting a 40-line version of it is
closer to what beni will emit (closures as continuations, no interpreter, no effect value) and makes
the yield primitive a one-line swap. `www/kernel.js`, reproduced in §3.

### 1.4 What `--headless=new` does to timing

Stated up front because four sections depend on it.

- **`requestAnimationFrame` fires.** Median inter-frame delta **16.7 ms**, min 16.6, max 16.8, over
  29 frames (`e10b.js`). Old `--headless` did not schedule frames reliably; `--headless=new` uses the
  same renderer with a headless frame sink.
- **It stretches under load, correctly.** With 18.6 ms of synchronous work per frame the wall-clock
  delta became 21.7 ms; with 55.8 ms it became 65.1 ms (four frame periods). Over 19 frames the rAF
  timestamp total and the wall-clock total agree to within 0.2 % in every case. (The *median* rAF
  timestamp delta stays 16.7 ms even under load because the distribution is bimodal — 16.7 and 33.4
  — so this report reports totals, not medians, for that quantity.)
- **There is no vsync and no display.** Frame jitter, compositor-thread scrolling, and anything
  involving actual paint are not represented.
- **`requestIdleCallback`'s period is not a real idle period** — §0.7.
- **Timer clamping is normal.** The 4 ms nested-timeout clamp reproduces exactly (§2.4).
- **Input injected by CDP takes the real input path.** `Input.dispatchMouseEvent` goes through the
  browser process's input pipeline, not `element.click()`, and queues behind a blocked renderer,
  which is the whole point of §3.2.

### 1.5 One measurement that had to be redesigned, and why it matters

The first two attempts at input latency (§3.2) returned a flat 0.1 ms for *every* configuration,
including a fiber that never yields. Two separate mistakes, both worth recording because anyone
repeating this will hit them:

1. **`event.timeStamp` is assigned when the event is dispatched to the DOM, not when it was
   injected**, so `performance.now() - event.timeStamp` measures nothing. The fix is to take a wall
   clock on the Node side just before `Input.dispatchMouseEvent` and `Date.now()` in the handler.
2. **`Runtime.evaluate` with `awaitPromise:false` still returns only after the *synchronous* part of
   the expression finishes**, so a fiber started that way had already run to completion before the
   first click was sent. The fix is to start the fiber from inside a `setTimeout(…, 10)`.

Both bugs produce a plausible-looking table of zeros. §3.2's numbers are from the third version.

### 1.6 What was not run

- **No Safari, and no WebKit of any kind.** Not available here.
- **No real device, no real network, no mobile CPU.** `Network.emulateNetworkConditions` is Chrome's
  token-bucket emulation, not a real radio; `Emulation.setCPUThrottlingRate` was not used.
- **No Firefox input injection**, so every input-latency number is Chrome-only. Firefox covers the
  primitive availability, per-hop cost, clamping, clock resolution, microtask starvation and defect
  behaviour, which is where cross-engine confirmation was cheapest and most load-bearing.
- **No Effect, no `npm i effect`.** §1.3.
- **No beni fiber runtime**, because none exists. Every §3 and §4 number is from the micro-kernel,
  and the work unit (465 ns) is stated so the slice lengths can be re-derived for a different one.

---

## 2. The scheduling primitives a fiber can yield through

### 2.1 The table

`e1.js`, Chrome 153 `--headless=new`, load 0.07. 20 000 sequential hops each, except the three slow
primitives at 300. "med/p99/max" are per-hop delays in ms as the page measures them
(`performance.now()` around one hop, so quantised to 0.1 ms — §2.5); "max hops/s" is a separate
bulk run.

```js
// e1.js — per-hop cost of each browser scheduling primitive (abridged: the prims map is the point).
const hop = (fn, n) => new Promise(res => { const d = []; let i = 0;
  const step = () => { const t = performance.now();
    fn(() => { d.push(performance.now() - t); if (++i < n) step(); else res(stats(d)); }); };
  step(); });
const bulk = async (fn, n) => { const t = performance.now(); await hop(fn, n);
  return +((n / ((performance.now() - t) / 1000)) | 0); };
const mc = () => { const c = new MessageChannel(); let cb = null;
  c.port1.onmessage = () => { const f = cb; cb = null; f(); }; c.port1.start(); c.port2.start();
  return f => { cb = f; c.port2.postMessage(0); }; };
const prims = {
  'queueMicrotask':         f => queueMicrotask(f),
  'Promise.resolve().then': f => Promise.resolve().then(f),
  'setTimeout(0)':          f => setTimeout(f, 0),
  'MessageChannel':         mc(),
  'postMessage(window)':    (() => { let cb=null; addEventListener('message', e => { if (e.data==='p'){const g=cb;cb=null;g();} });
                               return f => { cb=f; postMessage('p','*'); }; })(),
  'postTask user-blocking': f => scheduler.postTask(f, {priority:'user-blocking'}),
  'postTask user-visible':  f => scheduler.postTask(f, {priority:'user-visible'}),
  'postTask background':    f => scheduler.postTask(f, {priority:'background'}),
  'scheduler.yield':        f => scheduler.yield().then(f),
  'requestAnimationFrame':  f => requestAnimationFrame(() => f()),
  'requestIdleCallback':    f => requestIdleCallback(() => f()),
};
for (const [k, f] of Object.entries(prims)) {
  const n = /Animation|Idle|setTimeout|background/.test(k) ? 300 : 20000;
  out[k] = await hop(f, n); out[k].hops_s = await bulk(f, Math.min(n, 2000));
}
```

| primitive | med | p99 | max | max hops/s (Chrome) | max hops/s (Firefox 156) | input/render between hops? | clamping |
|---|---:|---:|---:|---:|---:|---|---|
| `queueMicrotask` | 0 | 0 | 0.1 | **1 052 631** | 666 666 | **no — nothing** (§2.3) | none |
| `Promise.resolve().then` | 0 | 0 | 0.6 | **2 499 999** | 2 000 000 | **no — nothing** | none |
| `setTimeout(f, 0)` | 4.1 | 4.4 | 4.4 | **245** | 242 | yes | **≥4 ms after 5 nesting levels** (§2.4) |
| `MessageChannel` | 0 | 0.1 | 0.6 | **256 410** | **500 000** | **yes, all of it** | none |
| `postMessage(window,'*')` | 0 | 0.1 | 1.1 | 165 289 | 285 714 | yes | none |
| `scheduler.postTask` `user-blocking` | 0 | 0.1 | 0.2 | 232 558 | 400 000 | input and rAF yes; **timers and `MessageChannel` starve** (§3.1) | none |
| `scheduler.postTask` `user-visible` | 0 | 0.1 | 0.1 | 273 972 | 400 000 | yes, all of it | none |
| `scheduler.postTask` `background` | 0 | 0.1 | 2 | 300 000 | 300 000 | yes | none |
| `scheduler.yield()` | 0 | 0.1 | 0.2 | 338 983 | 400 000 | input and rAF yes; **timers and `MessageChannel` starve** (§3.1) | none |
| `requestAnimationFrame` | **16.7** | 17 | 17 | **60** | 59 (17 ms) | yes | 60 Hz |
| `requestIdleCallback` | **50.1** | 50.5 | 50.6 | **20** | 10 (98 ms) | yes | idle period; headless artefact (§0.7) |
| `setImmediate` | — | — | — | — | — | — | **does not exist** in either engine |

The "max hops/s" numbers are a bulk loop and are the right per-hop figure; the median column is
0 because `performance.now()`'s resolution (100 µs) is coarser than a hop. From §3.4's interleaved
measurement the true per-hop costs are: `MessageChannel` **2.6–4.4 µs** (Chrome) / **2.1–2.3 µs**
(Firefox), `postTask user-visible` **3.7–4.9 µs**, `scheduler.yield` **1.4–2.6 µs**, a microtask
**0.4–0.5 µs**, `setTimeout(0)` **4.15–4.45 ms**.

**`setImmediate` is absent.** Confirmed by direct probe in both engines. R21 §0.5's warning is
correct: Effect v4's scheduler is a Node design, and its fallback is `setTimeout(f, 0)`, which at a
512-op budget would cap a browser fiber at about 128 000 ops/s — §3.4 measures that fallback at
**9.7×** the no-yield cost at a 0.48 ms slice.

### 2.2 Availability

`ffcaps.js`, both engines:

| | Chrome 153 | Firefox 156 |
|---|---|---|
| `MessageChannel`, `queueMicrotask`, `requestIdleCallback` | yes | yes |
| `scheduler.postTask`, `scheduler.yield`, `TaskController` | yes | **yes** |
| `navigator.scheduling.isInputPending` | yes | **no** |
| `PerformanceObserver` `longtask` | yes | **no** |
| `PerformanceObserver` `long-animation-frame` | yes | no |
| `navigator.userActivation` | yes | yes |
| `AbortSignal.any` | yes | yes |
| `setImmediate` | no | no |

Firefox's supported entry types are `event, first-input, largest-contentful-paint, mark, measure,
navigation, paint, resource`. Chrome adds `element, interaction-contentful-paint, layout-shift,
long-animation-frame, longtask, soft-navigation, visibility-state`.

For non-Chrome support of the two Chrome-only items, and for `scheduler.*` more generally, the
citations are in §13; nothing outside Chrome was measured for `isInputPending` because it does not
exist outside Chromium.

### 2.3 Microtasks starve everything — demonstrated

`e1b.js`. A promise/microtask loop runs for 500 ms with a `setTimeout(0)`, a rAF and a
`MessageChannel` ping armed before it starts.

```js
document.getElementById('x').innerHTML = '<button id=b>b</button>';
let clicked = -1, rafd = -1, timed = -1, mcd = -1, hops = 0;
const t0 = performance.now();
document.getElementById('b').addEventListener('click', () => { clicked = performance.now() - t0; });
setTimeout(() => { timed = performance.now() - t0; }, 0);
requestAnimationFrame(() => { rafd = performance.now() - t0; });
const ch = new MessageChannel(); ch.port1.onmessage = () => { mcd = performance.now() - t0; }; ch.port2.postMessage(0);
await new Promise(res => { const loop = () => { hops++;
    if (performance.now() - t0 < 500) queueMicrotask(loop); else res(); }; queueMicrotask(loop); });
```

| | Chrome 153 | Firefox 156 |
|---|---:|---:|
| microtask hops in the 500 ms | **761 519** | **861 589** |
| spin ended at | 500.0 ms | 500 ms |
| armed `setTimeout(0)` fired at | **502.5 ms** | **552 ms** |
| armed `requestAnimationFrame` fired at | **500.1 ms** | **551 ms** |
| armed `MessageChannel` ping fired at | **502.6 ms** | **552 ms** |

Nothing at all ran for half a second in either engine. This is P2 §7.5's premise — *"run
continuations in microtasks for throughput"* — meeting the measurement: §3.4 shows the throughput
it buys is **zero** once the slice is 0.12 ms or longer, and §3.2 shows the latency it costs is
653 ms.

### 2.4 Clamping, and the ordering between primitives

**The nested-`setTimeout` clamp**, measured by chaining 12 timers each armed from inside the
previous one (`e1.js`, `_setTimeout_clamp_by_nesting_ms`):

```
Chrome  : 0, 0, 0, 0, 0, 0, 4.4, 4.1, 4.3, 4.4, 4.1, 4.1     <- clamps from the 7th
Firefox : 0, 0, 0, 0, 5,  4,   4,   5,   4,   4,   4,   5    <- clamps from the 5th
```

Chrome follows HTML's "nesting level > 5 → at least 4 ms". Firefox clamps one level earlier. Either
way, **`setTimeout(0)` as a fiber's yield is a 4 ms floor**, which §3.4 prices at 9.7×.

**Ordering.** All seven armed in the same turn, completion order recorded (`e1b.js`) — **identical
in both engines**:

```
queueMicrotask, rAF, postTask/user-blocking, setTimeout0, MessageChannel, postTask/user-visible, postTask/background
```

Two things in that line matter. `postTask user-blocking` runs **before** `setTimeout` and
`MessageChannel` — which is why it starves them (§3.1). `postTask user-visible` runs **after** them,
which is why it does not.

### 2.5 The clock

`e1b.js` / `e7-ip.mjs`, cost measured against an empty loop of the same shape, 2–5 M iterations:

| | Chrome 153 | Firefox 156 |
|---|---:|---:|
| `performance.now()` cost | **140–166 ns** | **54–61 ns** |
| `performance.now()` resolution | **0.1 ms** (100 µs) | **1 ms** |
| `Date.now()` cost | **31–33 ns** | **50 ns** |
| `Date.now()` resolution | 1 ms | 1 ms |
| `crossOriginIsolated` | false | false |

Three consequences for a time-based budget:

1. **`Date.now()` is the right clock in Chrome** — 4.5× cheaper than `performance.now()` and at the
   same effective resolution for a ≥1 ms slice. In Firefox they are within 20 % of each other and
   both give 1 ms.
2. **Chrome's 100 µs / Firefox's 1 ms resolution puts a floor under the slice.** A 1 ms slice is
   *exactly* one tick in Firefox; anything below that cannot be enforced by a clock read at all, and
   has to be an op count. This is the reason §0.1 recommends a hybrid: an op counter as the inner
   loop, a clock read as the outer test.
3. **`crossOriginIsolated` is false here and will be false for most beni pages.** Cross-origin
   isolation (COOP+COEP) would give Chrome 5 µs resolution, but it also breaks third-party embeds
   and is not something a language should assume. The 100 µs / 1 ms figures are the ones to design
   against.

At a 465 ns work unit, a `Date.now()` read every 64 ops costs 0.11 %; every 512 ops, 0.014 %. At an
11 ns work unit those become 4.7 % and 0.6 %. **An op count `k` of 256–512 between clock reads keeps
the clock under 1 % for any plausible beni op cost**, which is what §11 Q1 recommends.

---

## 3. The yield-budget sweep, in the browser

### 3.1 Which primitives let the page breathe at all

`e2.js`. 1 000 000 units of a *cheap* work unit (one `Math.imul`, **11–12 ns**), one fiber, probes
armed before the run. The probe columns are how long the armed `setTimeout(0)`, `MessageChannel`
ping and rAF waited. Load 0.08.

```js
// e2.js (abridged) — the micro-kernel, one fiber, probes armed before it starts.
const sched = new K.Sched(kind, B, 0);
const t0 = performance.now(); let tT = -1, tC = -1, tR = -1;
setTimeout(() => { if (tT < 0) tT = performance.now() - t0; }, 0);
const c = new MessageChannel(); c.port1.onmessage = () => { if (tC < 0) tC = performance.now() - t0; };
c.port2.postMessage(0);
requestAnimationFrame(() => { if (tR < 0) tR = performance.now() - t0; });
const acc = await new Promise(r => K.runFiber(work, OPS, sched, r));
```

| primitive | budget | wall ms | armed timer | armed channel | armed rAF |
|---|---:|---:|---:|---:|---:|
| `microtask` | 16 | 53.7 | **53.8** | **53.9** | **53.8** |
| `microtask` | 64 | 17.9 | **18.1** | **18.2** | **18.2** |
| `microtask` | 512 | 12.0 | **12.0** | **12.0** | **12.0** |
| `MessageChannel` | 16 | 239.7 | 4.1 | 0.2 | 0.2 |
| `MessageChannel` | 64 | 67.6 | 0.1 | 0.1 | 0.3 |
| `MessageChannel` | 512 | 17.9 | 0.1 | 0.1 | 0.4 |
| `postTask` user-blocking | 16 | 274.8 | **282.1** | **282.2** | 8.9 |
| `postTask` user-blocking | 64 | 86.8 | **88.7** | **88.7** | 0.4 |
| `postTask` user-blocking | 512 | 17.3 | **17.6** | **17.6** | 0.2 |
| `postTask` user-visible | 16 | 244.8 | 0.1 | 0.1 | 0.5 |
| `postTask` user-visible | 512 | 17.6 | 0.0 | 0.0 | 0.1 |
| `scheduler.yield()` | 16 | 174.6 | **175.4** | **175.4** | 8.1 |
| `scheduler.yield()` | 64 | 46.6 | **47.0** | **47.0** | 0.2 |
| `scheduler.yield()` | 512 | 14.8 | **15.0** | **15.0** | 0.4 |
| none (`never`) | — | 11.7 | 11.8 | 11.8 | 11.8 |

**Bolded cells are starvation**: the probe fired only when the fiber finished.

Three findings.

1. **`microtask` starves at every budget.** The budget changes nothing, because the escape is also a
   microtask. This is §2.3 inside the kernel.
2. **`postTask` at `user-blocking` starves timers and `MessageChannel`**, at every budget, for the
   whole run. It is the priority-inversion trap: a fiber that declares itself user-blocking outranks
   the page's own timers. rAF still gets through (rendering is not a task).
3. **`scheduler.yield()` starves them too**, and for a subtler reason: a continuation from
   `scheduler.yield()` is scheduled *ahead of* same-priority tasks by design — that is the feature
   ("continuation priority"). Against a fiber that yields continuously, the page's timers never
   reach the front.

`MessageChannel` and `postTask user-visible` are the two that behave. The full sweep across budgets
16 → 8 192 for all eight primitives is in `out-e2.json`; the shape does not change.

### 3.2 Input latency, with real injected input

**The headline experiment.** `e3b-input.mjs`. 30 000 000 cheap units (~360 ms of work), a
`mousedown` injected every 20 ms by CDP into a 400×300 button, 30 events, latency measured as
`Date.now()` in the handler minus `Date.now()` in Node immediately before the dispatch — so it
includes CDP transport, which the idle row calibrates. Load 0.12.

```js
// e3b-input.mjs (abridged)
await p.ev(`document.getElementById('x').innerHTML='<button id=b style="width:400px;height:300px">B</button>';
  globalThis.HITS=[]; document.getElementById('b').addEventListener('mousedown',()=>HITS.push(Date.now())); true`);
// start from a *task* so Runtime.evaluate returns before the work begins (§1.5)
await p.ev(`setTimeout(() => { const s=new Kernel.Sched(${JSON.stringify(prim)},${budget},0);
  Kernel.runFiber((i,a)=>(a+Math.imul(i^(a>>>3),2654435761))|0, ${ops}, s, ()=>{DONE=true;}); }, 10); true`, false);
const sent = [];
for (let i = 0; i < 30; i++) { await new Promise(r => setTimeout(r, 20)); sent.push(Date.now());
  p.s('Input.dispatchMouseEvent', { type:'mousePressed', x:150, y:120, button:'left', clickCount:1, buttons:1 });
  p.s('Input.dispatchMouseEvent', { type:'mouseReleased', x:150, y:120, button:'left', clickCount:1, buttons:0 }); }
```

| yield | budget | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|---:|
| **idle page (control)** | — | 0 | 1 | 1 | **1** |
| **no yielding at all** | — | 84 | 324 | 364 | **364** |
| `microtask` | 64 | **371** | **612** | **653** | **653** |
| `microtask` | 512 | 172 | 414 | 454 | 454 |
| `microtask` | 2048 | 153 | 395 | 435 | 435 |
| `MessageChannel` | 16 | 0 | 1 | 1 | **1** |
| `MessageChannel` | 64 | 0 | 1 | 2 | **2** |
| `MessageChannel` | 512 | 0 | 1 | 1 | **1** |
| `MessageChannel` | 2048 | 0 | 1 | 1 | **1** |
| `MessageChannel` | 8192 | 0 | 1 | 1 | **1** |
| `postTask` user-blocking | 512 | 0 | 1 | 1 | 1 |
| `postTask` user-visible | 512 | 0 | 1 | 2 | 2 |
| `scheduler.yield()` | 512 | 0 | 1 | 2 | 2 |
| `requestAnimationFrame` | 8192 | 0 | 1 | 1 | 1 |

**Read the microtask rows again.** Yielding through microtasks every 64 ops is **1.8× worse at p50
and 1.8× worse at the tail than a fiber that never yields at all** — it pays 0.4 µs per hop 468 750
times and hands the page nothing. This is the single strongest result in the report, and it is the
one that kills P2 §7.5's design as written.

**And read the `MessageChannel` rows again.** At budget 16 and at budget 8 192 the input latency is
the same as an idle page. Which is the next section's problem: at an 11 ns work unit, budget 8 192 is
a 90 µs slice, so of course. **An op budget is not a latency control; a slice length is.**

### 3.3 The budget that matters is the slice, in milliseconds

`e2c-slice.mjs`. Same injected input, but a **realistic work unit** — 100 inner iterations,
calibrated at **476 ns** in this run — and ~300 ms of total work, so that the op budget spans slices
from 8 µs to 125 ms. Yield is always `MessageChannel`. Load 0.16.

```js
// e2c-slice.mjs (abridged) — the whole point is the slice_ms column.
// nsPerOp is calibrated in-page first (min of 5 over 200 000 units): 476 ns in this run.
const TOTAL = Math.round(300e6 / nsPerOp);        // ~300 ms of work per trial
await p.ev(`setTimeout(() => { const ch=new MessageChannel(), q=[]; ch.port1.onmessage=()=>q.shift()();
  const yieldTo=f=>{q.push(f);ch.port2.postMessage(0);};
  const W=(i,a)=>{for(let k=0;k<100;k++)a=(a+Math.imul(i^(a>>>3),2654435761))|0;return a;};
  let i=0,acc=0,n=0; const t0=performance.now();
  const step=()=>{ n=0; for(;;){ if(i>=${TOTAL}){WALL=performance.now()-t0;DONE=true;return;}
    acc=W(i,acc); i++; if(++n>=${B}){YIELDS++;return yieldTo(step);} } }; step(); }, 10); true`, false);
```

| budget (ops) | **slice (ms)** | yields | input p50 | **p90** | p99 | max | long tasks |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | **0.008** | 39 390 | 0 | **1** | 1 | 1 | 0 |
| 64 | **0.030** | 9 847 | 0 | **1** | 1 | 1 | 0 |
| 256 | **0.122** | 2 461 | 0 | **1** | 1 | 1 | 0 |
| 512 | **0.244** | 1 230 | 0 | **1** | 1 | 1 | 0 |
| 1 024 | **0.487** | 615 | 0 | **1** | 1 | 1 | 0 |
| 4 096 | **1.95** | 153 | 1 | **2** | 2 | 2 | 0 |
| 16 384 | **7.80** | 38 | 1 | **5** | 7 | 7 | 0 |
| 65 536 | **31.2** | 9 | 1 | **26** | 28 | 28 | 0 |
| 262 144 | **124.8** | 2 | 1 | **102** | 120 | 120 | **2, max 122 ms** |

**Input latency p90 ≈ the slice length**, from 2 ms upward, which is exactly what a uniformly
arriving event waiting on a uniformly-phased slice should do. Below ~1 ms the floor is the input
pipeline itself (1 ms, the same as the idle control).

The two published rules of thumb line up with the table and can be quoted against it:

- **RAIL / the frame budget: ~5 ms of script per 16.7 ms frame.** A 7.8 ms slice gives p90 5 ms /
  max 7 ms and drops no frame that §5.6 can see. A 31 ms slice is already two frame periods.
- **INP / long tasks: 50 ms.** The `longtask` observer fired for the first time at a **124.8 ms**
  slice (2 entries, max 122 ms) and never below it — consistent with the 50 ms long-task threshold
  and a 31 ms slice.

**So the slice ceiling for a UI is ~5 ms, and the floor is set by throughput, which §3.4 puts at
0.25 ms.** Anything in 0.25–5 ms is defensible; 1 ms is the middle of the defensible range on a log
scale and is one clock tick in Firefox.

### 3.4 What a yield costs, with an interleaved baseline

`e2e.js`, run through the POST-back harness in **both engines**. 400 000 units of the 465 ns work
unit; for each budget a no-yield baseline is measured **immediately before** each primitive, min of
7, after three warm-up rounds. This is the only throughput table in the report whose absolute
numbers are defensible.

```js
// e2e.js (abridged)
const best=async(y,B,reps=7)=>{let b=1e9,ys=0;for(let r=0;r<reps;r++){const x=await run(y,B);b=Math.min(b,x.ms);ys=x.ys;
  await new Promise(r2=>setTimeout(r2,15));}return {ms:b,ys};};
for (let w=0; w<3; w++) await best(null,0,2);               // JIT warm-up
for (const B of [16,64,256,512,2048,16384]) {
  const base = await best(null,0);                          // interleaved baseline
  for (const [k,y] of Object.entries(Y)) { if (k==='never') continue;
    const r = await best(y,B);
    rows.push({ prim:k, budget:B, base_ms:+base.ms.toFixed(1), wall_ms:+r.ms.toFixed(1),
      overhead_x:+(r.ms/base.ms).toFixed(2), yields:r.ys, ns_per_yield:+(((r.ms-base.ms)*1e6)/r.ys).toFixed(0) }); }
}
```

Chrome 153 (`ns_per_work_unit` 465.2, baseline ~188 ms):

| budget | slice ms | `microtask` | `MessageChannel` | `postTask` UV | `scheduler.yield` |
|---:|---:|---:|---:|---:|---:|
| 16 | 0.007 | 1.06× | **1.51×** | 1.51× | 1.31× |
| 64 | 0.030 | 1.02× | **1.15×** | 1.13× | 1.08× |
| 256 | 0.119 | 1.00× | **1.02×** | 1.03× | 1.02× |
| 512 | 0.238 | 1.00× | **1.01×** | 1.02× | 1.01× |
| 2 048 | 0.953 | 0.99× | **0.99×** | 0.99× | 0.99× |
| 16 384 | 7.62 | 1.00× | **1.00×** | 1.02× | 0.99× |

Firefox 156 (`ns_per_work_unit` 480, baseline ~191 ms):

| budget | slice ms | `microtask` | `MessageChannel` | `postTask` UV | `scheduler.yield` |
|---:|---:|---:|---:|---:|---:|
| 16 | 0.007 | 1.05× | **1.30×** | 1.36× | 1.36× |
| 64 | 0.031 | 1.02× | **1.07×** | 1.09× | 1.09× |
| 256 | 0.123 | 1.02× | **1.05×** | 1.04× | 1.04× |
| 512 | 0.246 | 0.99× | **1.01×** | 1.01× | 1.01× |
| 2 048 | 0.983 | 0.99× | **0.99×** | 0.99× | 1.00× |
| 16 384 | 7.86 | 0.99× | **0.99×** | 0.99× | 1.00× |

Per-yield cost, from the same runs (`(wall − base) / yields`, at the budgets where the difference is
above noise):

| | Chrome | Firefox |
|---|---:|---:|
| `queueMicrotask` | 0.43–0.53 µs | 0.40–0.48 µs |
| `MessageChannel` | **2.6–4.4 µs** | **2.1–2.3 µs** |
| `postTask` user-visible | 3.7–4.9 µs | 2.7–2.9 µs |
| `scheduler.yield()` | 1.4–2.6 µs | 2.7–2.8 µs |
| `setTimeout(f, 0)` | **4.15–4.45 ms** | — |

And `setTimeout` as a yield, Chrome, `e2d.js`, min of 5 without input traffic:

| budget | slice ms | overhead |
|---:|---:|---:|
| 1 024 | 0.477 | **9.70×** |
| 4 096 | 1.91 | **3.22×** |
| 16 384 | 7.63 | 1.56× |
| 65 536 | 30.5 | 1.13× |

**The conclusions.**

- **A macrotask yield is 2–4 µs.** At a 1 ms slice that is 0.2–0.4 %; at 0.25 ms, 1 %. Both engines
  agree and the crossover is in the same place.
- **Microtasks buy no throughput once the slice is ≥0.12 ms** — 1.00–1.02× against
  `MessageChannel`'s 1.02–1.05×, a difference of at most 3 % that costs 653 ms of input latency
  (§3.2). There is no trade here to make.
- **`setTimeout` is disqualified** by the clamp, as R21 §0.5 predicted.
- **Firefox's `MessageChannel` is faster than Chrome's** (2.1 vs 3.8 µs per hop in §2.1's bulk
  measure), so a budget chosen on Chrome is conservative for Firefox.

---

## 4. `isInputPending`, the budget rules compared, and the long-task view

### 4.1 What it costs to call

`e7-ip.mjs`, Chrome 153, 2 000 000 calls against an empty loop of the same shape:

| | ns per call |
|---|---:|
| empty-loop baseline | 0.9 |
| `navigator.scheduling.isInputPending()` | **180.1** |
| `isInputPending({includeContinuous: true})` | **250.7** |
| `Date.now()` | 33.3 |
| `performance.now()` | 165.6 |

**`isInputPending` costs about what `performance.now()` costs, and 5× what `Date.now()` costs.** It
cannot be called per op; it is an outer-loop test like the clock.

### 4.2 Eleven budget rules, one primitive, real input

Same script. 845 666 units of the 473 ns work unit (~400 ms of work), `MessageChannel` throughout,
40 `mousedown`s injected at 15 ms intervals. **Only the stopping rule changes.** Load 0.39–0.55, so
the `overhead` column is contaminated by the input traffic and by the machine; it is comparable
*within* the table and not against §3.4.

```js
// e7-ip.mjs (abridged) — `k` ops between checks, then `rule` decides whether to yield.
const RULES = {
  'ops 512':                   `{k:512,  rule:()=>true}`,
  'time 5ms (k=512)':          `{k:512,  rule:(s)=>Date.now()-s>=5}`,
  'inputPending (k=512)':      `{k:512,  rule:()=>navigator.scheduling.isInputPending()}`,
  'inputPending|5ms (k=512)':  `{k:512,  rule:(s)=>navigator.scheduling.isInputPending()||Date.now()-s>=5}`,
  /* … */ };
const step=()=>{let n=0;for(;;){ if(i>=TOTAL){…}
  acc=W(i,acc); i++; if(++n>=k){ if(rule(s)){YS++;s=Date.now();return yieldTo(step);} n=0; } }};
```

| rule | yields | input p50 | **p90** | p99 | max | long tasks | overhead |
|---|---:|---:|---:|---:|---:|---:|---:|
| ops 512 | 1 651 | 0 | **1** | 1 | 1 | 0 | 1.78× |
| ops 2 048 | 412 | 1 | **1** | 2 | 2 | 0 | 1.82× |
| ops 8 192 | 103 | 2 | **4** | 5 | 5 | 0 | 1.68× |
| ops 65 536 | 12 | 13 | **30** | 33 | 33 | 0 | 1.11× |
| time 1 ms (k=64) | 481 | 1 | **1** | 1 | 1 | 0 | 1.91× |
| time 5 ms (k=64) | 116 | 3 | **5** | 5 | 5 | 0 | 1.63× |
| time 5 ms (k=512) | 111 | 3 | **5** | 5 | 5 | 0 | 1.56× |
| time 50 ms (k=512) | 8 | 14 | **45** | 50 | 50 | 0 | 1.06× |
| `isInputPending` (k=512) | **37** | 0 | **1** | 1 | 1 | **1, 82 ms** | 1.70× |
| `isInputPending` \| 50 ms | 39 | 0 | **1** | 1 | 1 | **1, 50 ms** | 1.83× |
| **`isInputPending` \| 5 ms** | 128 | 0 | **1** | 1 | 1 | **0** | **1.61×** |

**The isInputPending result is real.** 37 yields buy the same input latency as 1 651 yields — a
**45× cut** — because the fiber yields only when there is something to yield *to*. That is worth
having.

**And it has a hole.** Alone, it produced an **82 ms long task**: with no input pending, the fiber
runs until it finishes, which means a dropped frame, a delayed timer, and a stalled `fetch`
continuation. `isInputPending` answers "is there input", not "does the page need the thread".
Capping it with a 5 ms slice fixes that and is the best row in the table on every axis at once —
fewest yields among the responsive rules except the uncapped one, p90 1 ms, zero long tasks.

**`time 1 ms (k=64)` is the most expensive responsive rule** (1.91×), which is the clock-read cost
showing through: at `k=64` and a 473 ns unit the rule reads the clock **13 213 times** over the run,
33 times per 1 ms slice, to make 481 decisions. At `k=512` the same 5 ms rule is 1.56×. This is §2.5's arithmetic, confirmed.

### 4.3 The Long Tasks / `PerformanceObserver` view

`new PerformanceObserver(l => …).observe({ type: 'longtask' })` in the page, per strategy. Across
every measurement in §3.3 and §4.2 the `longtask` entry fired in exactly three configurations:

| configuration | entries | longest |
|---|---:|---:|
| slice 124.8 ms (`e2c`, budget 262 144) | 2 | 122 ms |
| `isInputPending` uncapped | 1 | 82 ms |
| `isInputPending` \| 50 ms cap | 1 | 50 ms |

Everything else — including a 31 ms slice — produced **zero** entries, which is the 50 ms threshold
behaving as specified. So the long-task observer is a *coarse* instrument: it will not tell a beni
platform that it is dropping frames at a 31 ms slice, only that it is janking at 50 ms+.

**`longtask` does not exist in Firefox 156** (§2.2), so a beni platform cannot use it as its own
self-monitoring mechanism portably. `long-animation-frame` (LoAF) is Chrome-only too. If beni wants
a "your update handler took too long" diagnostic, it has to time its own slices — which the
scheduler is already doing, for free, under the recommendation in §0.1.

---

## 5. The synchronous constraints

### 5.1 `preventDefault` and `stopPropagation`

`e4-sync.mjs`. Real CDP-injected clicks on a real `<a href="#HASH">` and a real
`<form action="/landed.html">`; the handler hops through one primitive, then calls
`preventDefault()`.

```js
const hop = { sync:'', microtask:'await Promise.resolve();',
  channel:'await new Promise(r=>{const c=new MessageChannel();c.port1.onmessage=r;c.port2.postMessage(0)});',
  timeout:'await new Promise(r=>setTimeout(r,0));', raf:'await new Promise(r=>requestAnimationFrame(r));' };
await p.ev(`location.hash=''; globalThis.R=null;
  document.getElementById('lnk').onclick = async e => { ${h} e.preventDefault(); R = e.defaultPrevented; }; true`);
await click(await rect('lnk'));
```

| hop before `preventDefault()` | `event.defaultPrevented` afterwards | did the link navigate? | did the form submit? | did `stopPropagation` work? |
|---|---|---|---|---|
| none (`sync`) | true | **no** | **no** | **yes** |
| `await Promise.resolve()` (microtask) | true | **no** | **no** | **yes** |
| `MessageChannel` | true | **YES — `#HASH`** | **YES — `/landed.html`** | **no, the ancestor ran** |
| `setTimeout(0)` | true | **YES** | — | — |
| `requestAnimationFrame` | true | **YES** | — | — |

Two things to take from this.

1. **`event.defaultPrevented` lies.** It reads `true` in every row, because the flag is set on the
   object regardless. The *behaviour* is what differs. A beni platform cannot detect the mistake by
   asking the event; it has to prevent the mistake structurally, which is what `sync` is for.
2. **A microtask hop is still in time.** The microtask checkpoint runs when the listener callback
   returns to the agent, before the dispatch algorithm's remaining steps and before the activation
   behaviour. So `await` of an *already-settled* promise inside a handler is safe. This is a real
   property and it is also a trap: it means the mistake only shows up when the awaited thing
   happens to be slow, i.e. in production and not in the test.

### 5.2 What this says about `sync`'s scope

`sync` must cover, at minimum: every DOM event listener the platform installs on the user's behalf,
and every `requestAnimationFrame` callback (§5.4). The handler may compute, may call
`preventDefault`/`stopPropagation`, may read and write the DOM — and if it wants to do anything that
suspends, it **spawns a fiber and returns**. The fiber is then a normal fiber with a normal
scheduler and a normal canceller, and it has lost the right to prevent the default action, which it
had already lost the moment it suspended.

The open design question this raises for report 25 and for the platform: **the spawned fiber's
result has to get back into the UI somehow** (a message, a `Cmd`, a store write), and that is the
TEA boundary, not this report's subject.

### 5.3 Transient user activation

`e4b-act.mjs`, two passes, because **`window.open()` consumes the activation** and a naive single
pass reports that activation dies at the first microtask (it does not — the first `open()` killed
it). Pass 1 only reads `navigator.userActivation.isActive`; pass 2 does exactly one consuming call
per trial, at one delay, from a fresh click.

Pass 1 — the flag, cumulative delays from one click:

| observed at | `isActive` |
|---|---|
| sync | true |
| after a microtask | true |
| after a `MessageChannel` hop | true |
| after `setTimeout(0)` | true |
| after a rAF | true |
| +100 ms | true |
| +2 s (≈2.1 s cumulative) | true |
| +4 900 ms (≈7.0 s cumulative) | **false** |

Pass 2 — one `window.open()` per trial, from a fresh click:

| delay before `open()` | `window.open` succeeded |
|---|---|
| sync, microtask, channel, `setTimeout(0)`, rAF, +100 ms, +2 s, **+4 900 ms** | **yes** |
| **+5 200 ms** | **no** |

**So an activation-gated API is *not* on the `sync` list.** Chrome's transient activation duration is
5 seconds and it survives arbitrarily many macrotask hops inside that window. The HTML standard makes
the duration implementation-defined ("transient activation duration"), and Firefox also uses 5 s, so
a platform should treat this as "a few seconds, not a turn" and not as a guarantee.

**Could not determine here:** `navigator.clipboard.writeText` returned `NotAllowedError` and
`requestFullscreen` returned `TypeError` **even synchronously** in headless — both are gated on
things headless does not provide (a permission state, a real display). Their activation behaviour was
not measured; the spec places them in the same transient-activation class as `window.open`.

### 5.4 A `requestAnimationFrame` callback must not suspend

`e10.js`:

```js
requestAnimationFrame(async t0 => {
  await new Promise(r => { const c = new MessageChannel(); c.port1.onmessage = r; c.port2.postMessage(0); });
  const afterHop = performance.now();
  requestAnimationFrame(t1 => res({ rAF_callback_ts: t0, after_macrotask_hop: afterHop,
    slipped_ms: afterHop - t0, next_frame_ts: t1, write_lands_frames_later: (t1 - t0)/16.7 })); });
```

```
rAF_callback_ts        335.1
after_macrotask_hop    345.2      <- resumed 10.1 ms into the frame
next_frame_ts          351.7
write_lands_frames_later  0.99
```

The hop resumed **10.1 ms** after the callback started — the rest of that frame's budget — and a
write made there lands in the **next** frame. A rAF callback that suspends has, by construction,
missed its frame.

### 5.5 Reads and writes inside one pass

`e10b.js`, 3 000 `<div>`s, interleaved `offsetHeight` read + `style.height` write against the same
work with all reads first:

| | median of 12 |
|---|---:|
| interleaved read/write (layout thrash) | **2 846.6 ms** |
| batched read-then-write | **2.5 ms** |
| ratio | **1 139×** |

Headless Chrome does real layout, and forced synchronous layout is as catastrophic here as anywhere.
An earlier run at 200 nodes showed no difference at all (0.2 ms both ways) — below the clock's
resolution — which is a warning about how easy it is to measure this and see nothing.

For beni this is not a scheduler question but a **vdom patch-application** question, and it belongs
to report 25: the patcher must not interleave measurement with mutation. It is listed here because
it is the second reason a rAF callback cannot suspend — a suspension in the middle of a patch turns
one batched pass into two interleaved ones.

### 5.6 The frame budget, confirmed

`e10b.js`, 20 frames each, wall-clock deltas (the rAF-timestamp median is bimodal — §1.4):

| synchronous work per frame | wall-clock inter-frame delta (median) | total wall for 19 frames |
|---:|---:|---:|
| 0 ms | 16.7 ms | 310.7 ms |
| 4.7 ms | 16.7 ms | 316.6 ms |
| 18.6 ms | **21.7 ms** | 416.7 ms |
| 55.8 ms | **65.1 ms** | 1 245.6 ms |

4.7 ms of work per frame is free; 18.6 ms costs a frame; 55.8 ms costs four. This is the measured
basis for the "~5 ms slice" ceiling in §3.3 and it agrees with the published RAIL guidance (§13).

---

## 6. Cancellation in the browser

### 6.1 R21 §4.4, re-run in Chrome

`e5-cancel.mjs`. The same uncooperative primitive R21 used — `setTimeout(() => res('done'), 300)` —
cancelled at 50 ms, once under a runtime that owns the resume callback and once under native
`async`/`await` + `AbortController`.

```js
// owned continuation: the runtime holds resume; cancel calls it with Cancelled and never waits.
const owned = await new Promise(done => { let resume = null, cancelled = false, cleaned = false;
  const park = k => { resume = k;
    const timer = setTimeout(() => { if (!cancelled) { const r=resume; resume=null; r({tag:'Done',v:'done'}); } }, 300);
    return () => { clearTimeout(timer); cleaned = true; };        // the canceller
  };
  const canceller = park(exit => { at('owned: continuation resumed with ' + exit.tag);
    done({exit:exit.tag, at:performance.now()-T0, cleaned}); });
  at('owned: parked');
  setTimeout(() => { at('owned: cancelling'); cancelled = true; canceller();
    const r = resume; resume = null; r({tag:'Cancelled'}); }, 50); });
// native async + AbortController: the await cannot be abandoned.
const native = await new Promise(done => { const ac = new AbortController();
  (async () => { at('native: awaiting'); await new Promise(res => setTimeout(() => res('done'), 300));
     at('native: await returned'); if (ac.signal.aborted) at('native: noticed abort');
     done({ at: performance.now()-T0 }); })();
  setTimeout(() => { at('native: abort()'); ac.abort(); }, 50); });
```

Raw output:

```
   0ms owned:  parked
  50ms owned:  cancelling
  50ms owned:  continuation resumed with Cancelled
  50ms native: awaiting                          <- the native trial's own t=0
 100ms native: abort()                           <- 50 ms in, as in the owned trial
 351ms native: await returned
 351ms native: noticed abort
owned_unwind_at_ms    50        (from its own start)
owned_canceller_ran   true      (clearTimeout fired; the timer is not left armed)
owned_exit            "Cancelled"
native_unwind_at_ms   351       (on the shared clock; 301 ms from its own start)
```

| | Node (R21 §4.4, Effect v4) | **Chrome 153 (here)** |
|---|---:|---:|
| owned continuation | 57 ms | **50 ms** |
| native `async` + `AbortController` | 301 ms | **301 ms** |
| ratio | 5.3× | **6.0×** |

**The result holds, and the native number reproduces exactly.** 301 ms is 50 ms of waiting for
`abort()` to be *called* plus 251 ms of waiting for the promise the `await` is stuck on to settle;
the `AbortController` never had any power over that promise, in either runtime. The
owned-continuation path unwinds in the same turn as the cancel and runs its canceller, which
`clearTimeout`s the pending timer. Chrome is 7 ms faster than Effect v4 on the owned path because
there is no interpreter between the cancel and the continuation — the micro-kernel's `resume` is a
bare closure call (§1.3).

### 6.2 `fetch` + `AbortController`, which *is* abortable

Against a local Node server that either delays headers by 3 s (`/slowhead`) or streams 64 bytes
every 50 ms for 3 s (`/slowbody`). The server records when the socket closes.

| case | `abort()` at | headers at | **promise rejected after `abort()`** | bytes read | error | server saw socket close at |
|---|---:|---:|---:|---:|---|---:|
| before headers | 51.5 ms | never | **1.5 ms** | 0 | `AbortError: signal is aborted without reason` | **53 ms** |
| mid-body, early | 51.1 ms | never | **0.0 ms** | 0 | `AbortError` | **51 ms** |
| mid-body, after 500 ms of streaming | 500.2 ms | 52.7 ms | **0.1 ms** | 576 | `AbortError: BodyStreamBuffer was aborted` | **500 ms** |

**The connection really closes**, immediately, in all three cases, and the rejection is same-turn.
Bytes already read out of the stream stay read; the reader throws on its next `read()`.

So for a beni `Http` primitive the canceller is one line (`ac.abort()`), and the 301 ms from §6.1 is
the price of the primitives that have *no* abort — which in a browser is most of them: `setTimeout`
(cancellable, but only if you kept the id), `postMessage` round trips, `IndexedDB` requests,
`Notification` permission prompts, and any promise a `foreign` got from user JavaScript.

### 6.3 `AbortSignal` on listeners and timers

| mechanism | result |
|---|---|
| `addEventListener(…, { signal })` then `abort()` | listener removed; a subsequent `dispatchEvent` did **not** call it |
| `clearTimeout(id)` | free (below the clock's resolution) |
| `TaskController` + `scheduler.postTask(…, { signal })` then `abort()` | task **never ran**; the returned promise rejected with `AbortError`, same turn |

`TaskController` is the one place the platform hands you a canceller you did not have to write:
aborting it both removes the queued continuation and rejects the handle. If beni's scheduler slot is
ever `postTask`-based, its fiber canceller is `TaskController.abort()` and nothing else. `AbortSignal.any`
exists in both engines, which is what a structured-concurrency runtime needs to fan a parent's
cancellation into several child signals without holding a list.

---

## 7. Defects in a browser

### 7.1 What a throw actually does — measured, both engines

`e6.js`. A throw is placed in each kind of callback and the *next* callback of the same kind is
checked.

| where the throw is | reported to `window.onerror` | did the next callback of that kind run? |
|---|---|---|
| a `MessageChannel` task | yes | **yes** |
| a `requestAnimationFrame` callback | yes | **yes** |
| an event listener | yes | **yes** — and the *sibling* listener on the same element still ran, **and the event still bubbled to the ancestor** |
| a microtask | yes | **yes** |
| a `setTimeout` callback | yes | **yes** — and a timer armed before it still fired |
| a rejected promise with no handler | `unhandledrejection` | — |

Afterwards: the DOM was still mutable, rAF was still scheduling, and a further uncaught throw inside
rAF did not stop rAF from scheduling. **Identical in Chrome 153 and Firefox 156**, down to the list.

A stack overflow is **catchable**: `RangeError` in Chrome, `InternalError` in Firefox. It is not a
condition that kills anything either.

### 7.2 So "fatal" is something the platform implements

The owner's A1 decision — *"the process dies with a good report and a non-zero exit"* — has no
browser analogue. There is no process to die and no exit code to set. What a page can do, and what
each costs:

| option | what it does | costs |
|---|---|---|
| **(a) stop the scheduler** | the runtime sets a `dead` flag; every fiber resume, every event listener and every rAF callback returns immediately | ~10 lines and one branch on the hot path (or a swapped `yieldTo` that drops). The page is frozen but intact — half-applied DOM state stays on screen |
| **(b) tear down the root** | (a), plus remove every listener the platform installed (one `AbortController` for all of them — §6.3) and empty the root node | ~30 lines. Requires the platform to own every listener registration, which it should anyway |
| **(c) render a platform-owned crash screen** | (b), plus write the defect report into the root | the report text has to survive into the release build — §8's measurement says the release optimiser and `Reach.zig` will otherwise delete it. This is the option with a *size* cost |
| **(d) `console.error` the report and nothing else** | what Elm effectively does (report 24 has the source; Elm's kernel throws and the app is wedged with no message the user sees) | free, and invisible to a non-developer |
| **(e) an optional user hook** | `onDefect : Report -> ()`, called before (a)–(c) | one function pointer; the hazard is that the hook itself is beni code that can defect, so it must run under (a) already armed and must not be able to cancel the teardown |

Three things the measurements make concrete:

- **(a) is not optional.** Without it, a defect inside a fiber leaves the *other* fibers running on
  state nobody can vouch for, which is exactly what A1 rejected — and §7.1 shows the browser will
  happily keep running them.
- **(b) is cheap if and only if the platform owns every listener**, because `{ signal }` removal
  (§6.3) then makes teardown a single `abort()`. That is a constraint on the platform's API design,
  and it is worth writing down before the API exists.
- **There is no "non-zero exit".** A8 settled `exit 0 / 1 / 130` for Node. The browser equivalent has
  to be invented, and the test harness needs it: §9 measures fixtures whose "exit code" is a global
  the page sets, which works but is a convention the platform must define.

§11 Q6 hands the choice over.

---

## 8. Loading and size

### 8.1 What was built, and the one thing that was stubbed

`tests/corpus/run/Dictionaries.beni` copied into a throwaway project and built with the repo's
compiler at `657aa7b`:

```sh
zig build
zig-out/bin/beni build src/Main.beni --release --platform=node
```

**13 files, 21 682 raw bytes.** To load it in a browser exactly **one** file was replaced:
`platform/runtime.foreign.mjs`, whose only browser-hostile line is `import process from "node:process"`.
The stub is five lines and appends to a `<pre>` instead of writing to stdout:

```js
// BROWSER STUB of the Node platform's runtime.foreign.mjs — the only file changed.
export const run = (program) => {
  globalThis.__MAIN_AT = performance.now();
  const el = document.getElementById('out'); if (el) el.textContent = program.out;
  globalThis.__OUT = program.out; globalThis.__CODE = program.code;
};
```

That is a 488-byte file replacing an 848-byte one, so the tree measured is **21 322 bytes**.
`Node.foreign.mjs`, `String.foreign.mjs`, `List.foreign.mjs` and `Basics.foreign.mjs` needed **no
change at all** — they are pure JavaScript with no host references, which is `boundary.md` §4.1's
rule paying off. **Every variant produced byte-identical correct output** (`2\n1\n0\na,b\n1,2\n1\n`),
checked in the page on every run.

This is precisely the thing a browser platform replaces, and it is one file.

### 8.2 Time to `main` executed

`e8-load.mjs`. A fresh Chrome per sample, cache disabled, brotli served precompressed, CDP
`Network.emulateNetworkConditions`, median of 5 (spread ≤3 ms on the throttled rows). Load 0.23.
"main at" is `performance.now()` inside the stubbed `run`, i.e. from navigation start to `main`
having executed.

| network | shape | **main at (median)** | min | max | requests | wire bytes |
|---|---|---:|---:|---:|---:|---:|
| unthrottled localhost | 13 modules | 26 ms | 25 | 45 | 15 | 12 129 |
| | **one bundle** | **14 ms** | 12 | 32 | 3 | 4 260 |
| | 13 + `modulepreload` | 25 ms | 25 | 47 | 15 | 12 205 |
| 4G — 9 Mbps, 170 ms RTT | 13 modules | 1 059 ms | 1 056 | 1 065 | 14 | 11 827 |
| | **one bundle** | **358 ms** | 356 | 359 | 2 | 3 958 |
| | 13 + `modulepreload` | 705 ms | 705 | 707 | 14 | 11 903 |
| fast 3G — 1.6 Mbps, 562 ms RTT | 13 modules | 3 437 ms | 3 437 | 3 437 | 14 | 11 827 |
| | **one bundle** | **1 156 ms** | 1 156 | 1 156 | 2 | 3 958 |
| | 13 + `modulepreload` | 2 282 ms | 2 282 | 2 289 | 14 | 11 903 |

**The bundle is 3.0× faster to `main` on 4G and 3.0× on fast 3G.** `modulepreload` for the whole
graph recovers 33 % of the gap on 4G and 51 % on fast 3G — worth having, and not a substitute.

The mechanism is **round-trip depth, not bytes**. The import graph is
`main.mjs → Main.mjs → {Dict, String, Node, Maybe, List} → {Basics, …}` — four levels — and the
browser cannot discover level *n+1* until level *n* has arrived and been parsed. At 170 ms RTT that
is four serialised round trips minimum; at 562 ms it is four × 562 ms ≈ 2.25 s, which is most of the
3 437 ms. `modulepreload` collapses the *discovery* into one level (all 12 hrefs are in the HTML) but
not the *connections*: the numbers say it still costs about half of the multi-file penalty, which is
consistent with HTTP/1.1's six-connection limit against 13 resources.

**Caveat, stated plainly:** the server is HTTP/1.1. Over HTTP/2 or HTTP/3 the `modulepreload` row
would improve — one connection, 13 concurrent streams — and the bare multi-file row somewhat less
(discovery is still serialised). **The bundle row does not change**: two requests is two requests.
That was not measured here and §12 records it.

### 8.3 Size, decomposed

| shape | raw | brotli | gzip |
|---|---:|---:|---:|
| 13 files, each compressed on its own (what a server sends) | 21 322 | **7 538** | 8 976 |
| the same 13 files concatenated, then compressed | 21 322 | **6 380** (−15.4 %) | 7 396 (−17.6 %) |
| an `esbuild --bundle --format=esm --tree-shaking=false` bundle | **16 102** | **3 269** (−56.6 %) | 3 678 (−59.0 %) |

R12's chunking **−22 % brotli** is in the same family as the middle row. The bottom row is much larger,
and the decomposition says why:

| | bytes | share of the tree's raw bytes |
|---|---:|---:|
| whole-line comments | **8 837** | **42 %** |
| `import`/`export` statement lines | 3 365 | 16 % |
| the `.foreign.mjs` siblings (never minified) | **15 267** | **71.6 %** |
| the compiler's own emitted `.mjs` | 6 055 | 28.4 % |

**Most of the bundle's win is not the compression window; it is that bundling is the first stage in
the pipeline that touches the sibling JavaScript at all.**
[`plans/state-of-the-compiler.md`](../../../plans/state-of-the-compiler.md) records "sibling `.js` is
never minified and is 44–76 % of small programs"; this measures 71.6 % for `Dictionaries` and prices
what that costs. One 6 014-byte `String.foreign.mjs` with a licence-style header block is a third of
the brotli budget of a whole program.

So there are two separable wins sitting in front of `backend.md` §10, and they should be counted
separately:

1. **One file instead of thirteen** — the §8.2 latency result, 3.0×, which needs nothing but
   concatenation with the `import`/`export` edges resolved.
2. **Minifying the sibling JavaScript** — a size win that is currently forfeited, worth roughly the
   difference between the middle and bottom rows above (6 380 → 3 269 brotli), and orthogonal to
   chunking. `boundary.md` §4 says nothing about the siblings' *shape*, only their exports, so
   nothing in the contract forbids it.

`derived_bytes` is 0 and `Reach.zig` is doing its job; this is the next thing in line.

---

## 9. How a browser platform gets tested

### 9.1 Cost per fixture, measured

`e9-harness.mjs`. The fixture is a trivial ES-module page that writes six lines into `<pre>`,
`console.log`s them, and sets `globalThis.__EXIT = 0` — i.e. output, a log stream and an "exit code",
the three things `tests/corpus/run/` compares today. The harness waits for the page's done flag,
reads the output and the exit code back, and closes.

| approach | n | min | **median** | max |
|---|---:|---:|---:|---:|
| **(a1)** one Chrome process per fixture | 8 | 267 ms | **271.6 ms** | 277.9 ms |
| **(a2)** one Chrome, a fresh `Target` per fixture | 40 | 16.0 ms | **18.5 ms** | 46.6 ms |
| **(a3)** the same, 8 targets in flight | 8 | — | **10.0 ms** (79.9 ms wall / 8) | — |
| **(b1)** a plain `node -e` process (the DOM-free core) | 8 | 24.8 ms | **25.8 ms** | 29.8 ms |
| **(b2)** `jsdom` in a fresh node process | 8 | 498 ms | **511.3 ms** | 518.7 ms |
| **(b3)** `happy-dom` in a fresh node process | 8 | 231 ms | **235.1 ms** | 238.1 ms |

**Process reuse is worth 15×** (272 → 18.5 ms) and parallelism another 1.85× (18.5 → 10.0 ms). A
fresh `Target` is a fresh JavaScript realm with fresh globals and a fresh DOM, so it is as isolated
as a process for everything a corpus fixture can observe; what it shares is the renderer process's
V8 isolate group and the browser process, which is also where the speed comes from.

### 9.2 Why the DOM emulators lose

Beyond being 13–28× more expensive per fixture than (a2):

| | `requestAnimationFrame` | `MessageChannel` | `queueMicrotask` | `getComputedStyle` | layout |
|---|---|---|---|---|---|
| `jsdom` | **absent** | **absent** | present | present (stub) | none |
| `happy-dom` | present | **absent** | present | present (stub) | none |

**Neither has `MessageChannel`** — the primitive §0.1 recommends the scheduler be built on. A
scheduler test under either would be testing a different scheduler. Neither has layout, so §5.5's
1 139× is invisible to them, and neither reproduces the event-loop ordering of §2.4. They are a
worse answer at a higher price.

### 9.3 Virtual time

CDP `Emulation.setVirtualTimePolicy` with `policy: 'pauseIfNetworkFetchesPending'` and a 60 000 ms
budget. Five chained 10-second timers:

```
five 10s timers: { wall: 50000, ticks: 5 }     <- Date.now() inside the page advanced 50 000 ms
real elapsed:    0.9 ms
```

**50 seconds of virtual time in 0.9 ms of real time**, with `Date.now()` inside the page advancing
consistently. Timers, and everything downstream of them, run at full speed with correct ordering.

Against beni's own swappable clock and scheduler slots (the owner's A7 decision), the trade is:

| | CDP virtual time | beni's clock/scheduler slots |
|---|---|---|
| needs cooperation from the program | **no** | yes — the program must read time through the slot |
| covers `setTimeout` in a `foreign` sibling | **yes** | no |
| covers CSS transitions, `fetch` timing, rAF | **yes** | no |
| available outside Chromium | no | yes |
| available in a beni unit test with no browser | no | **yes** |
| machinery | one CDP call | a slot the runtime already has |

**They are for different jobs and the corpus should have both.** Virtual time is the right default
for a `run/`-style fixture that would otherwise sleep, because it needs no cooperation and it catches
timer use in `foreign` code that a slot would silently miss. The clock slot is the right answer for a
beni-level test of a debounce written in beni.

### 9.4 The gate budget

Measured on this machine, `master` at `657aa7b`, twice:

```
zig build test-blackbox   ->  1m50.5s  and  1m56.1s real   (10m30s user; exit 0)
tests/corpus/**/*.beni    ->  668 fixtures, of which run/ is 125
```

(The build runner prints two `failed command:` lines for steps that write informational tables to
stderr — the doc-example gate and the incremental skip-decision table — and still exits 0. The gate
is green.)

A browser kind at (a3)'s **10 ms per fixture** would cost:

| browser fixtures | added wall time | as a share of today's gate |
|---:|---:|---:|
| 50 | 0.5 s | +0.5 % |
| 125 (the size of `run/` today) | **1.3 s** | **+1.2 %** |
| 300 | 3.0 s | +2.7 % |

Even at (a2)'s serial 18.5 ms, 300 fixtures is 5.6 s. **The constraint "a browser kind must not
double the gate" is satisfied by two orders of magnitude**, provided the harness keeps one Chrome
alive across the whole run rather than spawning one per fixture — which is the single decision that
matters, and it is worth 15×.

### 9.5 Flake sources, and what determinism requires

Named because rule 5 makes them a correctness question, not a convenience one:

1. **A shared browser process is shared state.** Two fixtures in flight can contend for the renderer
   and for the network stack. `Target.createTarget` gives a fresh realm, not a fresh process; a
   fixture that measures *time* will see the other one. **So: timing assertions must go through
   virtual time (§9.3), never through a real wall clock.**
2. **rAF is a real clock.** A fixture that waits "two frames" waits 33 ms of real time and will flake
   under load. Virtual time drives rAF too.
3. **Console ordering across targets is not ordered.** Each target's `Runtime.consoleAPICalled`
   stream is ordered within itself; comparing across fixtures is meaningless. Capture per target.
4. **`--headless=new` is not the same renderer configuration as a visible tab** (§1.4). A golden that
   encodes a frame count or an idle-callback deadline encodes a headless artefact.
5. **Chrome's version is an input.** The emitted JavaScript is compared, not the browser's behaviour,
   for most fixtures — but anything asserting on scheduling order has Chrome's version in its
   answer. Pin it, or assert only on things §2.4 shows are cross-engine stable.

The determinism test's shape (`--jobs=1` vs `--jobs=8`, twice each, byte-compare) transfers
unchanged: a browser fixture's observable output is the page's text, its console stream and its exit
global, all of which are byte-comparable.

### 9.6 The recommendation

**One long-lived `--headless=new` Chrome for the whole `test-blackbox` run; one fresh `Target` per
fixture; up to 8 in flight; `Emulation.setVirtualTimePolicy` on by default for any fixture that
mentions time; capture `Runtime.consoleAPICalled`, the root element's text and a platform-defined
exit global; ~10 ms per fixture.** The DOM-free core (scheduler, fibers, the TEA loop, vdom *diff*)
stays testable under plain `node` at 26 ms per process, which is where a fast inner loop lives; it is
not where the coverage lives, because patching, events and rAF are exactly the parts that are not
DOM-free.

---

## 10. What this changes in the existing documents

| document | what it says | what this measures |
|---|---|---|
| **P2 §7.5** | *"Run continuations in microtasks for throughput; escape to a macrotask every 64 resumptions"* | **the premise is wrong in a browser.** Microtasks buy 0–3 % throughput above a 0.12 ms slice (§3.4) and cost up to 653 ms of input latency (§3.2). There is no microtask tier to have. The two-tier design collapses to one tier: a macrotask every slice |
| **P2 §7.5** | the budget is **64**, *"a `foreign`-configurable platform constant"* | the "platform constant" half is right and is now the owner's A7 scheduler slot. The number should not be an op count at all (§3.3) |
| **R21 §9.3 / §0.5 item 2** | Node's knee is **512**, *"a Node platform wants 512, not 64"* | unchallenged for Node, and **not transferable**: 512 is 5.6 µs at an 11 ns op and 240 µs at a 465 ns op (§3.3). The browser's answer is a millisecond figure |
| **R16 §6** | the browser was *"unmeasured"*; it asked for a rAF latency histogram at budgets 16/64/512/2048 in Chrome and Firefox | done, and the right axis turned out to be input latency rather than rAF: rAF is satisfied by *any* macrotask yield at *any* budget tested (§3.1), while input is the axis that separates them (§3.2) |
| **R21 §0.2 item 1** | owning the resume callback: 57 ms vs 301 ms | **50 ms vs 301 ms in Chrome** — the native figure reproduces exactly (§6.1) |
| **`backend.md` §10** | release output is chunks; with one entry point a release build is exactly one file — specified, not built | the latency number for that: **3.0× to `main` on 4G** (§8.2). R12's −22 % brotli was the size number |
| **`plans/state-of-the-compiler.md`** | *"sibling `.js` is never minified and is 44–76 % of small programs"* | 71.6 % for `Dictionaries`; comments are 42 % of the tree's raw bytes; minifying them is worth 6 380 → 3 269 brotli, separately from bundling (§8.3) |
| **`plans/effects-decisions.md` A1** | defects are fatal, the process dies with a non-zero exit | **there is no such thing in a page** (§7.1). Five options in §7.2; the decision is open |
| **`plans/effects-decisions.md` A7** | three fixed per-fiber slots: clock, **scheduler**, log context | the scheduler slot is load-bearing and the browser default is now measured (§0.1). The clock slot has a second job — §9.3 — and a resolution constraint: 100 µs Chrome, 1 ms Firefox (§2.5) |

---

## 11. Questions for the owner

Each has options and a recommendation. None is decided here.

**Q1. The browser scheduler's default budget rule.**
(a) an op count, as P2 §7.5 and R21 §9.3 have it;
(b) a pure time slice, `Date.now()` read every op;
(c) **a hybrid — count `k` ops, then read `Date.now()`, yield when the slice is spent.**
*Recommended: (c), with `k = 256` and a **1 ms** slice.* (b) is unaffordable (33–50 ns per op against
a 465 ns op is 7 %, §2.5) and unenforceable below the clock's resolution. (a) makes the slice depend
on a per-program constant that varies 40× (§3.3). (c) costs 0.03 % for the clock and 0.35 % for the
yield, gives input p90 of 1 ms, and is one clock tick in Firefox — the smallest slice that is
*measurable* in both engines. A 5 ms slice is also defensible (§3.3's RAIL ceiling) and trades 4 ms
of input latency for 0.25 % of throughput; 1 ms is recommended because there is nothing to buy with
the throughput.

**Q2. The browser scheduler's default primitive.**
(a) `MessageChannel`; (b) `scheduler.postTask` at `user-visible` with a `MessageChannel` fallback;
(c) `scheduler.yield()`.
*Recommended: (a).* It is in every engine, it is the fastest macrotask in Firefox, and it cannot
starve or be starved. (b) is 20 % more expensive per hop for no measured benefit and needs the
fallback anyway. (c) is disqualified as a *default* by §3.1 — a continuation-priority yield starves
the page's own timers — though it is the right *alternative slot* for a fiber that genuinely should
outrank them.

**Q3. Does beni's browser scheduler use `isInputPending`?**
(a) no; (b) yes, capped by the time slice; (c) yes, uncapped.
*Recommended: (b), behind a capability check, as an optimisation and never as the rule.* It buys a
45× cut in yield count at identical input latency (§4.2), which matters for a fiber doing long
compute; uncapped it drops frames (an 82 ms long task); and it does not exist in Firefox, so the
time slice has to be the rule and `isInputPending` an early exit from it. Cost: one 180 ns call per
`k` ops, which at `k = 256` is 0.15 %.

**Q4. Is `sync` a property of the handler, or of the platform's registration?**
(a) the language marks a function `sync` and the checker rejects suspension inside it;
(b) the platform's `on`/`subscribe` primitives take a `sync` function type and nothing else can be
passed.
*Recommended: (b) first, with (a) as the mechanism that makes (b) checkable.* §5.1's finding that
`event.defaultPrevented` reads `true` even when `preventDefault` was too late means this cannot be a
runtime check or a lint; it has to be a type. The list in §0.2 is the set of registration points that
need it.

**Q5. Does the platform allow a `sync` handler to await a *microtask*?**
(a) no — `sync` means no suspension of any kind;
(b) yes, microtask-only suspension is permitted.
*Recommended: (a).* §5.1 measures that (b) is *correct today* in Chrome — a microtask hop preserves
`preventDefault` and `stopPropagation`. It is still the wrong rule, because whether a suspension is
microtask-only is not a property the caller can see: `List.map` over a `where`-constrained method may
or may not suspend depending on the receiver, which is exactly the hazard
[`plans/effects-plan.md`](../../../plans/effects-plan.md) §2.1 already names for `core/List.js`. A
rule that is sometimes right is worse than a rule that is always conservative.

**Q6. What is "fatal" in a page?**
(a) stop the scheduler; (b) + tear down the root; (c) + a platform crash screen;
(d) `console.error` only, Elm's behaviour; (e) + an optional user hook.
*Recommended: (a)+(b) always, (c) in development builds only, (e) as a v2 addition.* (a) is forced by
A1's own reasoning and by §7.1 — the browser will keep running the other fibers otherwise. (b) is
nearly free *if* the platform owns every listener through one `AbortController` (§6.3), which is a
constraint worth adopting now. (c) has a release-build size cost (§8.3's arithmetic: a crash-screen
string table is exactly the kind of thing `Reach.zig` cannot see is live), so gating it on the
development build keeps the release floor where the release optimiser put it. **And a sub-question that needs an answer
either way: what replaces the non-zero exit code?** §9 needs one to test with.

**Q7. Does the single-file bundle move ahead of chunking?**
(a) chunking first, as `backend.md` §10 and `fast-compiler.md` §13 have it;
(b) the degenerate one-entry-point single file first, chunking after.
*Recommended: (b).* §8.2 says the single file is worth **3.0× time-to-`main` on 4G** and
`backend.md` §10 already states that *"with one entry point and no `lazy`, a release build is exactly
one file"* — the degenerate case needs no colouring lattice, no merge pass, no threshold and none of
§10's PENDING decisions about `lazy`. It is the part of the chunking work that is unblocked, and it is the part
with the measured payoff.

**Q8. Is sibling JavaScript minified in a release build?**
(a) no, as today; (b) yes, by the release optimiser; (c) yes, by requiring the platform to ship it
minified.
*Recommended: (b) as a question to answer, not a recommendation to adopt* — it is worth **6 380 →
3 269 brotli** on `Dictionaries` (§8.3), it is orthogonal to chunking, and `boundary.md` §4
constrains only the siblings' *exports*, not their formatting. The objection is real and belongs to
the owner: minifying `core/`'s hand-written JavaScript makes a defect report point into text nobody
can read, which collides with Q6 and with the debugging quality R21 §8.2 sets as the bar.

**Q9. What does the corpus's browser kind use for time?**
(a) CDP virtual time; (b) beni's clock slot; (c) both.
*Recommended: (c), virtual time by default.* §9.3 measures virtual time at 50 s of timers in 0.9 ms
with no cooperation from the program, which also covers `setTimeout` inside a `foreign` sibling that
a slot cannot see. The clock slot stays for tests written in beni about beni code.

---

## 12. Could not determine

1. **Safari / WebKit — nothing at all.** Not available here. Every "both engines" claim is Chrome +
   Firefox. `MessageChannel`, `queueMicrotask`, `AbortController` and `navigator.userActivation` are
   long-standing in WebKit; `scheduler.postTask` and `scheduler.yield` are not, so a `postTask`-based
   scheduler slot would need the `MessageChannel` fallback in any case (§13 for the support tables).
2. **`beforeunload`.** Headless Chrome does not present the dialog and CDP's
   `Page.javascriptDialogOpening` path was not wired. The claim in §0.2 is from the spec, not from
   measurement.
3. **Passive `touchmove` / `wheel` `preventDefault`.** No touch device and no synthesised touch
   sequence was driven; the mechanism is the same as §5.1's but it was not measured.
4. **Clipboard and fullscreen activation gating.** Both failed *synchronously* in headless
   (`NotAllowedError`, `TypeError`), so their activation behaviour is unmeasured (§5.3).
5. **HTTP/2 and HTTP/3.** §8.2's server is HTTP/1.1. The `modulepreload` row would improve over a
   multiplexed connection; the bundle row would not change. The 3.0× is therefore an HTTP/1.1
   number and the true figure over H2 is somewhere between 3.0× and the compression-only ratio.
6. **A real device and a real network.** `Network.emulateNetworkConditions` is a token bucket;
   `Emulation.setCPUThrottlingRate` was not used, so every throughput figure is a 5950X core.
7. **Firefox input latency.** No input injection without WebDriver BiDi. §3.2 and §4.2 are Chrome-only.
8. **The cost of a *beni* fiber's yield.** §3.4 measures the yield primitive, not beni's
   continuation; the work unit is 465 ns and a real beni op is unknown until the spike exists. Every
   op-count figure in this report should be re-derived from the slice lengths once it is.
9. **Whether a 1 ms slice survives a real page.** Every measurement here is a blank page with one
   fiber. A page with a vdom patch pass, CSS animations and a compositor may not give the thread back
   at the same cadence. §3.3's law (p90 ≈ slice) is the thing to re-check first.
10. **Elm's behaviour.** §7.2 row (d) attributes "the app is wedged" to Elm from the commission's own
    framing; **report 24 has the source and should be treated as the authority.** Nothing here was
    read from Elm's runtime.

---

## 13. Evidence index

### Scripts (scratchpad `browser-r3/`)

| script | what it measures | section |
|---|---|---|
| `harness.mjs` | the 40-line CDP client over Node's `WebSocket` | §1.1 |
| `postsrv.mjs`, `xengine.mjs` | the protocol-free POST-back harness (this is what runs Firefox) | §1.1 |
| `serve.mjs`, `loadsrv.mjs` | static servers; the latter serves brotli precompressed | §1.1, §8.2 |
| `www/kernel.js` | the fiber micro-kernel: run queue, op budget, pluggable yield | §1.3, §3 |
| `www/e1.js`, `www/e1b.js` | per-hop cost, clamp curve, clock cost, ordering, microtask starvation | §2 |
| `www/ffcaps.js` | API availability, both engines | §2.2 |
| `www/e2.js` | the budget sweep with armed probes | §3.1 |
| `e3b-input.mjs` | input latency under a running fiber, CDP-injected | §3.2 |
| `e2c-slice.mjs` | slice length vs input latency vs long tasks | §3.3 |
| `www/e2d.js`, `www/e2e.js` | throughput, min-of-N, interleaved baseline, both engines | §3.4 |
| `e7-ip.mjs` | `isInputPending` cost and eleven budget rules | §4 |
| `e4-sync.mjs`, `e4b-act.mjs` | `preventDefault`, `stopPropagation`, transient activation | §5.1–§5.3 |
| `www/e10.js`, `www/e10b.js` | rAF suspension, layout thrash, frame budget, headless cadence | §5.4–§5.6, §1.4 |
| `e5-cancel.mjs` | R21 §4.4 re-run; `fetch` abort; `TaskController`; listener signals | §6 |
| `www/e6.js` | what a throw does, both engines | §7.1 |
| `e8-load.mjs` | time to `main` under emulated network, three shapes | §8.2 |
| `sizes.mjs` | raw/brotli/gzip, per file and concatenated | §8.3 |
| `e9-harness.mjs` | per-fixture cost, virtual time, jsdom/happy-dom | §9 |

### Raw output

`out-e1.json`, `out-e1-ff.json`, `out-e2.json`, `out-e2c.json`, `out-e2d.json`, `out-e2e-chr.json`,
`out-e2e-ff.json`, `out-e3b.json`, `out-e4.json`, `out-e4b.json`, `out-e5.json`, `out-e6.json`,
`out-e6-ff.json`, `out-e7.json`, `out-e8.json`, `out-e9.json`, `gate.txt`, `gate2.txt`.

### Specifications and documentation cited

| claim | source |
|---|---|
| nested `setTimeout` clamping ("nesting level > 5 → 4 ms") | HTML Standard, *timers* — <https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timer-initialisation-steps> |
| transient activation, and its implementation-defined duration | HTML Standard, *tracking user activation* — <https://html.spec.whatwg.org/multipage/interaction.html#transient-activation> ; <https://developer.mozilla.org/en-US/docs/Web/Security/User_activation> |
| the event dispatch algorithm and when the default action runs | DOM Standard, *dispatching events* — <https://dom.spec.whatwg.org/#dispatching-events> |
| microtask checkpoints and "perform a microtask checkpoint" | HTML Standard, *event loops* — <https://html.spec.whatwg.org/multipage/webappapis.html#perform-a-microtask-checkpoint> |
| `scheduler.postTask` and its three priorities | WICG/W3C *Prioritized Task Scheduling* — <https://wicg.github.io/scheduling-apis/> ; <https://developer.mozilla.org/en-US/docs/Web/API/Scheduler/postTask> |
| `scheduler.yield()` and continuation priority (Chrome ≥ 129) | <https://developer.mozilla.org/en-US/docs/Web/API/Scheduler/yield> ; <https://developer.chrome.com/blog/introducing-scheduler-yield> |
| `isInputPending` | WICG *is-input-pending* — <https://wicg.github.io/is-input-pending/> ; <https://developer.chrome.com/blog/isinputpending> (Chromium only) |
| Long Tasks, 50 ms threshold | W3C *Long Tasks API* — <https://w3c.github.io/longtasks/> |
| RAIL: ~50 ms for input response, the frame budget for animation | <https://web.dev/articles/rail> |
| INP and its thresholds | <https://web.dev/articles/inp> |
| `modulepreload` | HTML Standard, *link type "modulepreload"* — <https://html.spec.whatwg.org/multipage/links.html#link-type-modulepreload> |
| `performance.now()` resolution and cross-origin isolation | <https://developer.mozilla.org/en-US/docs/Web/API/Performance/now> ; <https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated> |
| `AbortSignal` on `addEventListener`, `AbortSignal.any` | DOM Standard — <https://dom.spec.whatwg.org/#interface-AbortController> |
| cross-engine support for the `scheduler.*` family | <https://caniuse.com/mdn-api_scheduler_posttask> ; <https://caniuse.com/mdn-api_scheduler_yield> |
| CDP `Emulation.setVirtualTimePolicy`, `Network.emulateNetworkConditions`, `Input.dispatch*` | <https://chromedevtools.github.io/devtools-protocol/tot/Emulation/> ; <https://chromedevtools.github.io/devtools-protocol/tot/Network/> ; <https://chromedevtools.github.io/devtools-protocol/tot/Input/> |

### In-repository references

`CLAUDE.md` (the Target bullet, 2026-09-19); `docs/design/transparent-effects-proposal.md` §6, §7,
§7.2, §7.3, §7.5; `docs/design/research/21-effect-v4-runtime.md` §0, §0.5, §4.4, §9.3;
`docs/design/research/16-fibers-and-concurrency.md` §6; `docs/design/research/12-js-output-and-chunking.md`;
`docs/design/backend.md` §9, §10; `docs/design/boundary.md` §4, §4.1, §5.2;
`plans/effects-decisions.md` (the "Answered by the owner" block, A1/A7/A8);
`plans/effects-plan.md` §2.1; `plans/effects-spike.md` E-M10; `plans/state-of-the-compiler.md`.
Report 24 (Elm's browser runtime as built) and report 25 (the UI architecture design space) are
written in parallel with this one and are the authority on their subjects.
