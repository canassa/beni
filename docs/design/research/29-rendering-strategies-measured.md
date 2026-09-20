# How fast can a beni UI be? Rendering strategies measured against SolidJS 2

**Commissioned by** the project owner's direction of 2026-09-20, recorded in
[`plans/queue.md`](../../../plans/queue.md)'s last section — ***"I want built in JSX in the
language. Also, clone and research SolidJS 2. I want a Beni UI to be fast, as fast as solid, the
runtime cannot be a limitation."*** The browser design pass that preceded it
([`research/24`](24-elm-browser-runtime.md), [`25`](25-ui-architecture-design-space.md),
[`26`](26-browser-host-measured.md) and [`plans/browser-decisions.md`](../../../plans/browser-decisions.md))
recommended The Elm Architecture and **assumed a virtual DOM**. W1's rider says so in as many words:
*"`view` returns a data tree the platform renders — a virtual DOM. No document in `docs/design/`
specifies one."* The owner's requirement re-opens that, which is why W1, W4, W5, W6 and W10 were
withdrawn pending this report.

**The question, stated once.** Can beni keep The Elm Architecture — one immutable model, a pure
`sync` `update`, `view : Model -> Html Msg`, exhaustive messages, time travel — **and** render as
fast as Solid, by having a compiler that sees JSX as markup, knows every type, knows purity and has
immutable data emit something smarter than a virtual DOM? Or does Solid-class speed require signals
as the *programming model*?

**What this is.** Measurements. js-framework-benchmark (krausest) in headless Chrome 153 on this
machine, driven by a harness that reproduces the official trace-based duration rule, against ten
framework implementations taken unmodified from the benchmark repo, a Solid 2 port of the same app,
and **eight hand-written prototypes of what a beni compiler could plausibly emit** — all running the
same app against the same DOM. Plus four experiments the table
benchmark cannot see, and a separate measurement of what `update` alone costs when `rows` is beni's
`List`.

**What this is not.** It is not a reading of Solid's source — that is
[report 27](27-solid-2-as-built.md). It is not a language design for JSX — that is
[report 28](28-jsx-in-beni.md). It takes no decisions: §13 hands the owner numbered questions
`F1`…, each with options and a recommendation.

**Citations.** Scripts are named as they sit in the scratchpad (`bench.mjs`, `lib/trace.mjs`,
`proto/p2-template.js`, …) and the ones that matter are reproduced inline; §15 is the full index.
`R24`, `R25`, `R26` are reports 24, 25 and 26; `W1`…`W24` are
[`plans/browser-decisions.md`](../../../plans/browser-decisions.md)'s questions.

**Read §0, then §13.** §0 is the answer and the tables; §13 is the owner's question list. §1–§12
are the evidence.

**One engine.** Every number is Chrome `153.0.8010.47`, `--headless=new`, on a Ryzen 9 5950X running
Linux 6.12.110. §1.5 says exactly what that inflates and by how much, and §14 lists what could not
be determined.

**Manager's validation note (2026-09-20).** The seven-subject core of §5 was re-run by the manager on
a quiet machine (load 0.06 at start; `out/manager-rerun.json`, n = 10, throttled). **The ranking
reproduces exactly** — total geo: vanillajs 1.015, P3 1.031, P2 1.058, Solid 1.9 1.095, Solid 2
1.142, P4 1.157, P1 1.221 — as do the per-operation script medians to within ~10 % (P2 beats Solid 2
on script on 9 of 9 and Solid 1.9 on 7 of 9, as stated; `select`: P3 0.67, P2 1.52, Solid 1.9 1.45,
Solid 2 2.96, P1 5.12 ms). **One headline does NOT reproduce: "P3 reaches vanilla's script cost
(script geo 0.989)".** In the re-run it is **1.260** (P2 1.389, Solid 1.9 1.578, Solid 2 2.194, P1
2.841), because that figure is a geometric mean of ratios dominated by sub-millisecond operations:
vanillajs's `swap` measured 0.10 ms of script here against 0.57 in the report's run, which alone moves
the mean by ~20 %. Read the script geo column as an ORDERING with a noise floor of roughly ±0.25, not
as a parity claim; the order P3 < P2 < Solid 1.9 < Solid 2 ≈ P4 < P1 is stable across both runs.

---

## 0. Findings

### 0.1 The one-line answer

**Yes. The Elm Architecture reaches Solid's speed and passes it, and the thing that gets it there is
not a virtual DOM.** A hand-written prototype of what beni's compiler could emit — JSX compiled to a
`<template>` plus hole paths, the view update re-run top-down from the root on every message, each
hole comparing its own input by `===`, the list hole reconciling row *instances* by key — beats
**Solid 2.0.0-rc.9 on all nine operations of js-framework-benchmark** and beats **Solid 1.9 on seven
of nine** — the two it does not win are `select`, where Solid 1.9 has a hand-written
`createSelector`, and `remove`, by 0.06 ms — while the programmer writes one immutable model, a pure
total `update`, and messages. Adding one compiler analysis on top — which model fields each hole reads — takes it to **the script
cost of hand-written keyed vanilla JavaScript** (geometric mean 0.989 against vanillajs's 1.000,
against Solid 2's 1.767).

**The reason it works is a property of beni, not a trick.** Every value is immutable and a record
update is emitted as a spread, so an unchanged row is *the same object* and `===` on it means
"deeply unchanged". A virtual DOM cannot use that, because it throws the old tree away and builds a
new one; a signal graph does not need it, because it tracks writes instead. A compiled template with
per-hole reference checks is the one design that *spends* it.

**And the virtual DOM that W1's rider assumed is the slowest architecture measured that is not
React.** Geometric mean 1.232 against the best subject, against Solid 2's 1.168 and compiled
templates' 1.068; on `select` it costs **5.64 ms of script against 0.49**. `lazy` rescues it —
2.336 → 1.323 on the script geometric mean, the largest single improvement in this report — at the
price of a memoisation annotation on every list row whose correct form is not obvious and whose
absence is silent.

**And the table benchmark understates the gap, because its list hole is the whole app.** On an
ordinary page — 2 000 elements of mostly static markup, 50 dynamic holes, one changing per message —
a virtual DOM costs **146× a compiled template** per message, and 565× under 4× CPU throttling
(§11.1). A template costs 2.25 µs there, which is 0.013 % of a frame; the virtual DOM costs 327 µs.
That is the shape of almost every real screen, and it is where the architectures actually differ.

### 0.2 The table

Median milliseconds, click to paint, from a Chrome trace, official CPU throttling, n = 10.
**`geo`** is the official normalisation (per benchmark, the ratio to the fastest subject, geometric
mean); **`script`** is the geometric mean of the script-only ratios against `vanillajs`, which §1.5
argues is the comparable column on a headless machine. Prototypes in **bold**.

| subject | create 1k | replace | update 10th | select | swap | remove | create 10k | append | clear | geo | script | brotli | ready MB | 1k MB | 10k MB |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs-lite | 38.5 | 45.5 | 22.0 | 4.4 | 27.3 | 23.3 | 496 | 46.3 | 19.2 | **1.007** | 0.536 | 992 | 0.50 | 1.61 | 11.1 |
| vanillajs | 40.9 | 46.9 | 21.8 | 4.9 | 27.1 | 23.5 | 496 | 46.0 | 18.5 | 1.024 | 1.000 | 2 172 | 0.51 | 1.79 | 12.8 |
| vanillajs-3 | 40.0 | 45.7 | 22.7 | 4.4 | 27.6 | 23.1 | 517 | 48.7 | 19.9 | 1.031 | 0.569 | 1 016 | 0.49 | 1.65 | 11.6 |
| **P3 no selector** | 40.9 | 47.3 | 23.3 | 4.9 | 27.5 | 23.6 | 521 | 48.0 | 19.3 | **1.050** | 1.051 | 1 806 | 0.53 | 1.85 | 12.8 |
| **P3 field deps** | 41.3 | 47.6 | 23.6 | **4.6** | 28.3 | 23.5 | 520 | 47.7 | 20.4 | **1.054** | **0.989** | 1 808 | 0.53 | 1.85 | 12.8 |
| **P3 over `List`** | 40.0 | 47.1 | 26.0 | 4.4 | 29.4 | 24.0 | 522 | 48.4 | 18.8 | **1.056** | 1.080 | 3 872 | 0.59 | 1.93 | 13.2 |
| **P2 templates** | 41.1 | 47.0 | 23.5 | 5.7 | 28.1 | 23.5 | 518 | 47.7 | 19.1 | **1.068** | 1.143 | 1 682 | 0.53 | 1.84 | 12.8 |
| **P2 over `List`** | 40.4 | 46.5 | 25.7 | 5.6 | 28.6 | 23.1 | 520 | 48.0 | 18.6 | **1.071** | 1.198 | 3 758 | 0.59 | 1.93 | 13.1 |
| Solid 1.9 | 42.3 | 49.7 | 26.6 | 5.4 | 28.9 | 23.9 | 524 | 48.1 | 19.5 | 1.098 | 1.322 | 4 358 | 0.54 | 2.59 | 20.2 |
| blockdom | 42.7 | 49.5 | 26.2 | 6.2 | 29.8 | 23.5 | 524 | 47.8 | 18.5 | 1.107 | 1.290 | 5 152 | 0.60 | 2.40 | 17.4 |
| inferno | 42.8 | 50.8 | 26.3 | 6.5 | 29.6 | 23.8 | 541 | 50.0 | 20.9 | 1.142 | 1.572 | 9 469 | 0.57 | 2.65 | 20.2 |
| ivi | 41.3 | 50.2 | 26.5 | 7.0 | 30.2 | 23.5 | 533 | 49.3 | 23.3 | 1.159 | 1.544 | 3 878 | 0.58 | 2.18 | 15.7 |
| **P1 vdom + `lazy`** | 44.3 | 50.6 | 26.1 | 6.8 | **28.9** | 24.0 | 539 | 49.2 | 23.2 | **1.159** | 1.323 | 1 787 | 0.51 | 2.53 | 19.3 |
| **Solid 2.0.0-rc.9** | **43.0** | **51.2** | **28.4** | **7.2** | **30.7** | **24.0** | **532** | **49.9** | **20.3** | **1.168** | **1.767** | **22 163** | **0.73** | **2.96** | **20.6** |
| **P4 TEA on signals** | 43.5 | 50.4 | 28.2 | 7.2 | 30.4 | 24.4 | 531 | 49.4 | 20.7 | **1.168** | 1.828 | 22 375 | 0.73 | 2.93 | 20.2 |
| svelte 5 | 42.6 | 51.5 | 26.5 | 8.5 | 31.1 | 24.8 | 531 | 49.8 | 20.5 | 1.186 | 1.788 | 9 809 | 0.61 | 2.78 | 20.5 |
| **P1 vdom** | 43.2 | 51.0 | 28.5 | **9.8** | 31.2 | 24.3 | 543 | 50.4 | 22.7 | **1.232** | 2.336 | 1 787 | 0.51 | 2.46 | 18.6 |
| elm 0.19 | 49.1 | 58.2 | 38.9 | 8.6 | 41.1 | 32.7 | 583 | 62.0 | 23.2 | 1.426 | 2.708 | 25 523 | 0.74 | 3.62 | 27.8 |
| react-hooks 19 | 47.7 | 58.7 | 29.7 | 9.9 | 193.1 | 24.0 | 748 | 54.0 | 31.7 | 1.686 | 4.829 | 52 423 | 1.12 | 4.34 | 31.0 |

Memory columns are `performance.measureUserAgentSpecificMemory()` after a major GC, in megabytes;
§9 adds the JavaScript-heap-only figure, which is the one that separates the strategies.
`brotli` is the whole page's JavaScript, brotli 11, **as served** — the prototypes are not minified
and their minified figures are the ones in §12.1.

### 0.3 The verdict, per strategy and per operation

"As fast as Solid" needs a definition. Three are used here: **within measurement noise** (the
medians differ by less than the larger standard deviation), **within 5 %**, and **within 1.2×**.

| strategy | against **Solid 2** | against **Solid 1.9** | where it is not, and why |
|---|---|---|---|
| **P2** — templates, per-hole `===` | **faster on 9 of 9** (script 1.08–2.18×) | faster on 7 of 9 | `select` 1.71 ms vs 1.38 (Solid's hand-written `createSelector`); `remove` 0.51 vs 0.45 (noise) |
| **P3** — + field dependencies | **faster on 9 of 9** (1.03–5.31×) | faster on 7 of 9 | `remove` 0.47 vs 0.45 and `clear` 17.55 vs 17.39 — both inside the spread |
| **P3 over beni's `List`** | faster on 9 of 9 | faster on 8 of 9 | it is still ahead of both Solids; the cons list shows against its own array twin — `update 10th` 1.27 vs 1.20, `swap` 1.05 vs 0.77, `append` 2.83 vs 2.69 (§10) |
| **P4** — TEA over Solid 2's runtime | **identical**, within noise on every operation | slower on 9 of 9 | it *is* Solid 2's runtime |
| **P1** — virtual DOM | **slower on 8 of 9**; `select` **2.2× slower** | slower on 9 of 9 | it rebuilds the view of 1 000 rows to find the two that changed |
| **P1 + `lazy`** | faster on 6 of 9, notably `swap` (0.44 vs 1.29) and `update 10th` (1.10 vs 2.35) | slower on 6 of 9 | `select` 2.31 vs 1.38 — the thunks still have to be built and compared |

**Does P2 suffice? Yes.** It beats the bar on every operation in the benchmark, with no analysis
beyond "split the static markup from the holes" — which report 28 §8.1 argues the compiler should
do anyway, over ordinary `Html.div` calls, JSX or no JSX.

**Does P3 close the rest, and what does it demand?** It closes `select`, which is the only operation
where P2 is behind Solid 1.9, and it does so by a factor of 3.5. What it demands is a per-hole
free-variable analysis over the view body — an ordinary use-def walk — and, for the last fifth of
the win, a syntactic recognition of `x == model.f` inside a keyed list hole. §7.4 separates the two:
**the field diff is worth 1.03 ms of P2's 1.30 ms `select` cost and the selector recognition 0.24**.
A compiler that manages only the first still lands at 1.051 against vanillajs.

**Is P4 worth its runtime? No.** It produces Solid 2's numbers exactly, because it is Solid 2's
runtime, and it costs **22 375 brotli bytes against P3's 1 808** — 12× — to discover at run time
what the compiler discovered at compile time.

**Is anything paint-bound, so the question is moot?** Mostly, and this is the largest single fact in
the report. On seven of the nine operations the paint every subject pays is larger than the whole
spread of script between the best and worst sensible renderer: `create 1k` is 36–39 ms of paint
around 2.0–7.8 ms of script; `create 10k` is 459–493 around 22–249; `swap` is 25–28 around 0.3–2.5.
R27 §10.4 reached the same conclusion from the framework's side and states the consequence best:
*"an architecture 2× slower than Solid in its own layer is 2–15 % slower end to end."* The two
operations where it is **not** true are `clear` — all script, no paint, 16–21 ms for everyone,
because it is Chrome destroying 1 000 `<tr>`s — and `select`, 0.15–5.64 ms of script against 3 ms of
paint. **`select` is the whole argument**, and it is the operation the ordinary-UI experiments in
§11 generalise.

### 0.4 What it implies for the programming model

**The Elm Architecture can stay, at Solid-class speed, with these compiler features:**

1. **The compiler must see the markup and split it into a static template plus hole paths.** This is
   the single load-bearing feature and it is what report 28's JSX decision buys — though report 28
   §8.1 is right that a recogniser over `Html.div [..] [..]` calls gets the same thing, and should,
   so that the plain-call form is never the slow path.
2. **The language must promise that a record update preserves the identity of every field it does
   not name.** It is true today by construction and nowhere written (R24 §6.8). Without it, `===`
   on a row does not mean "unchanged" and the whole strategy is unsound. This is F4 and it is the
   one thing here that has to go into `language.md`.
3. **The compiler should learn which model fields each hole reads** — not required, worth 0.15 of a
   geometric mean here. §11.1 bounds it honestly: the field diff pays where ONE field feeds MANY holes, and not where each hole has a field to itself.
4. **Nothing else.** No `lazy`, so W4's recommendation (b) stands and its two-demands-in-argument-position
   cost is not incurred. No signals, so R25 §7's hazard and W19's fourth fiber slot stay closed. No
   virtual DOM, so W10's "how much of the diff is written in beni" is the wrong question — there is
   no diff.

R25's guarantees all survive, because none of them is touched: one model, a pure `sync` `update`
applied atomically, exhaustive `Msg`, messages as data, and therefore time travel (W21). The
rendering strategy is invisible to every one of them.

### 0.5 What beni's data representation must be

**`rows` as a cons list is not what makes the table benchmark slow — but it is a capability gap, and
the benchmark is the wrong place to look for the damage.** §10 measures beni's compiled `update`
against an array-backed one. At 1 000 rows the cons version costs a fraction of a millisecond more
per message, which is invisible next to a 28 ms operation. What is not invisible:

* **`List` has no indexed read at all.** "Swap rows 1 and 998" cannot be written in beni except by
  walking to each element and rebuilding the spine with `indexedMap` — which is exactly what the
  compiled `update` in §2.1 does, because it is what the source says. `List.length` is a fold.
* **A renderer over a `List` has to materialise an array to reconcile**, and under P2 — which re-runs
  top-down — it does so on *every* message, including ones that do not touch `rows`. Under P3 the
  field diff means it does so only when `rows` changed, which is rung 3 paying for itself a second
  time, for a reason nothing to do with selectors.
* `backend.md` §4 has parked this since M3 began — *"cons cells …, pending M3c's benchmark of a
  vector trie"* — and §10 is that benchmark.

The recommendation is F3: **`core/Array`, a persistent indexable sequence**, on rule 7's ground that
only `core/` may write `foreign`, so whatever it does not ship the language is withholding. With the
caveat §10.4 records: a copy-on-write JavaScript array beats both a cons list and a 32-way trie for
everything this benchmark does, so *which* array is a second question nobody has answered.

### 0.6 Questions for the owner

Eight, in §13, ids `F1…F8`:
**F1** data tree or compiled template (recommend: template, built as P2 then P3) ·
**F2** when the field analysis lands (recommend: second) ·
**F3** does `core/` get an indexable sequence (recommend: yes) ·
**F4** does `language.md` promise field identity (recommend: yes, and this is the one that must be
written down) · **F5** the "work out what changed" budget (recommend: 1 ms) ·
**F6** does `lazy` come back (recommend: only if F1 is the virtual DOM) ·
**F7** is the equality-keyed selector a compiler pattern (recommend: not yet, and never a
programmer-written one) · **F8** anything left for signals as the programming model (recommend: no,
in writing).

**What this re-issues from `plans/browser-decisions.md`:** W1's third rider — *"`view` returns a
data tree the platform renders — a virtual DOM"* — should be replaced by F1. W4 is unchanged in its
recommendation but its reasoning is now measured rather than assumed (F6). W10 — *"how much of the
virtual DOM is written in beni"* — does not survive F1(b)/(c): there is no diff to write. W5, W6,
W7, W8, W9 are untouched by anything here.

### 0.7 Caveats on every number above

**Headless Chrome 153, one engine, one machine, this harness.** Totals are roughly 2× the published
ones and all of the difference is paint (§1.5); the *ranking* matches the published table on nine of
ten adjacent pairs (§5.2) and reproduces react-hooks's framework-specific swap pathology, which is
the strongest check available. The script column matches the published figures to a few tenths of a
millisecond. No GPU, no vsync, no real device, no Firefox, no Safari, no wasm (Leptos was not built).
The prototypes are hand-written, so they bound what a compiler could reach rather than predict it,
and they ship no element vocabulary, no event system beyond one delegated listener, no XSS
sanitisation and no runtime — §12.1 says what that does to the size column. §14 is the full list.

---
## 1. Method

### 1.1 What was driven, and with what

| Piece | Version / commit |
|---|---|
| Chrome | `153.0.8010.47`, `--headless=new` |
| Node | `v24.19.0` |
| js-framework-benchmark | `652198560d0ccdafb9be833dac53e154bd1a0d1d` (2026-09-12), shallow clone |
| official results it ships | `webdriver-ts/results.json`, 3 840 rows, produced on **Chrome 152.0.7977.65** (`webdriver-ts-results/src/App.tsx:28`) |
| beni | `master` at `4b29ac9`, `./zig-out/bin/beni` |
| Solid | `solid-js@1.9.3` (the repo's `frameworks/keyed/solid`) |
| Solid 2 | `solid-js@2.0.0-rc.9`, `@solidjs/web@2.0.0-rc.9`, `@solidjs/signals@2.0.0-rc.9`, built with `@solidjs/vite-plugin@3.0.0-next.35` on Vite 8.3.0 + terser |
| Elm | `0.19.2` via `nix run nixpkgs#elmPackages.elm`, `--optimize`; **not** uglified (see §1.6) |
| Svelte | 5.42.1 · **ivi** 5.1.0 · **Inferno** 8.2.2 · **React** 19 (`react-hooks`) · **blockdom** 0.9.26 |
| machine | Ryzen 9 5950X (16c/32t), Linux 6.12.110, 1-minute load average, recorded at the start of each batch: **0.40–0.98** through the nine throttled benchmarks, **0.71** for the unthrottled pass, **0.4–1.5** for the rest |

Chrome is launched with the official benchmark's flags, copied from
`webdriver-ts/src/webdriverCDPAccess.ts`'s `buildDriver`: `--window-size=1280,800`,
`--js-flags=--expose-gc`, `--enable-precise-memory-info`, `--disable-cache`,
`--disable-background-timer-throttling` and the rest, plus `--headless=new --disable-gpu
--no-sandbox`.

### 1.2 The harness, and why it is a port and not a wrapper

The official runner is Selenium + chromedriver + a TypeScript build. R26 §9 already established
that one long-lived Chrome plus a fresh `Target` per fixture is 15× cheaper than a process per
fixture, and R26's 40-line CDP client over Node 24's built-in `WebSocket` already existed in the
scratchpad. So this report **ports the official measurement rule** rather than running the official
runner: `lib/trace.mjs` is a line-for-line port of
`webdriver-ts/src/timeline.ts`'s `computeResultsCPU`, `computeResultsJS` and `computeResultsPaint`,
and `lib/benchmarks.mjs` is a port of `benchmarksWebdriverCDP.ts` — same warm-up counts, same
post-conditions, same rows clicked.

The rule, verbatim from the original:

* start tracing with exactly the official categories — `blink.user_timing`, `devtools.timeline`,
  `disabled-by-default-devtools.timeline`;
* dispatch a **real** click (`Input.dispatchMouseEvent` `mousePressed`/`mouseReleased` at the
  element's centre), so the trace carries an `EventDispatch{type:"click"}`;
* `duration = (the first Commit after the LAST of {click, FireAnimationFrame, TimerFire, Layout,
  FunctionCall}).end − click.ts`, in milliseconds, with the official ">16 ms rAF delay"
  correction;
* `script` and `paint` are the **unions** of the JS-side and paint-side event intervals inside
  `[click.ts, commit.end]`, computed by the same `newContainedInterval` cleanup.

So the numbers here are click-to-paint, from a trace, exactly as the published table's are. They
are **not** `performance.now()` plus a double-rAF: that fallback was not needed.

CPU throttling is applied where the official benchmark applies it
(`benchmarksCommon.ts`'s `throttlingFactors`): **4×** on `03_update10th1k`, `04_select1k`,
`05_swap1k` and `09_clear1k`, **2×** on `06_remove-one-1k`, 1× elsewhere; via
`Emulation.setCPUThrottlingRate`, set after the warm-up and reset before the trace is closed.

### 1.3 Iterations, rotation, and what a median is over

Ten measured iterations per (subject, benchmark) after the official warm-up, each in a **fresh page
target** — a fresh JavaScript realm, a fresh DOM, a fresh id counter. Inside each iteration the
subject list is **rotated** (iteration *i* starts at subject *i* mod *n*), so a subject is never
systematically measured at the same point in a thermal or load drift. The tables report the median;
the standard deviation of the ten is reported beside it in §5.3, and it is small enough
(§5.3) that the ranking is not an artefact of spread.

The official runner uses 15 iterations and a *fresh browser process* per iteration. Ten and a fresh
target is the compromise R26 §9.6 already recommends; the cost is that a long-lived browser's heap
and JIT state are shared across iterations of *different subjects*, which the rotation is there to
average out.

### 1.4 Validating the harness against the published table

The benchmark repo ships the official `webdriver-ts/results.json` from a Chrome 152 run. The
ranking my harness produces is checked against it in §5.2. **If the two rankings disagree, the
harness is wrong** — that was the instruction, and it is the right one.

### 1.5 What headless costs, and what it does not

Absolute totals here are roughly **2× the published ones**, and the whole of the difference is in
paint. On `01_run1k`:

| | official (Chrome 152) | here (Chrome 153, headless) |
|---|---|---|
| vanillajs total / script / paint | 20.6 / 1.8 / 18.4 | ≈41 / ≈2.5 / ≈37 |
| solid total / script / paint | 21.4 / 2.7 / 18.3 | ≈41 / ≈3.2 / ≈37 |

`--headless=new --disable-gpu` rasterises in software, so every paint is inflated by about the same
constant factor for every subject. Dropping `--disable-gpu` was tried and made it slightly *worse*
(44.3 against 43.3 median over three runs), so it stays.

Two consequences, and they run through the whole report:

1. **`script` is the comparable column.** It matches the published figures to within a few tenths
   of a millisecond, and it is the column the question is actually about — "the runtime cannot be a
   limitation" is a claim about script time.
2. **`total` overstates how paint-bound the operations are.** On a GPU-composited desktop Chrome the
   paint column would be roughly half of what it is here — so where this report says an operation is
   paint-bound, the published table agrees (vanillajs `01_run1k` is 1.8 ms of script inside 20.6 ms
   of total), and where it says script dominates, that is true *a fortiori* off headless.

Every number in §5–§7 is therefore quoted with its script/paint split, and the verdicts in §0 are
argued on script.

### 1.6 Where this deviates from the official runner, deliberately

| Deviation | Why | What it costs |
|---|---|---|
| one long-lived browser, fresh page target per iteration | R26 §9: 15× | shared JIT/heap across subjects; the rotation averages it |
| 10 iterations, not 15 | time | slightly wider CI; the sd column is published |
| Elm is `elm make --optimize` without the uglify pass | the framework's `build-prod` also runs `uglifyjs --compress 'pure_funcs="F2..A9"…' && uglifyjs --mangle`, which the official table includes | Elm's **size** figure here is its raw `--optimize` output, 128 577 B, against the official table's 31.7 kB compressed-ish figure; its **speed** is essentially unaffected, because the `pure_funcs` pass removes wrapper calls that V8 inlines anyway — but this is an assumption, not a measurement, and §14 records it |
| Solid 2 has no entry in the benchmark repo, so the app was ported | there is no `solid-next` framework directory | the port is reproduced in full in §4.2 and passes the same DOM assertions |
| memory uses both `performance.measureUserAgentSpecificMemory()` and CDP `Runtime.getHeapUsage` | the official runner uses the first; the brief asked for the second | both columns are published (§9) |

### 1.7 Correctness first: every subject drives the same DOM

Before any timing, `verify.mjs` drives all nine buttons on all nineteen subjects and asserts the DOM
after each: 1 000 rows created, row 2 selected and carrying `danger`, rows 2 and 999 swapped and
swapped back, row 991's label ending in ` !!!`, a row removed, 1 000 appended, cleared, 10 000
created, and the row's shape (4 `<td>`, `col-md-1`, an `<a>`, a `glyphicon glyphicon-remove`
`<span>`, `col-md-6`). All nineteen pass. The output is `out/verify.txt` and is reproduced in §15.

This matters more for the prototypes than for the frameworks: a fast renderer that does not produce
the right DOM is not a measurement of anything.

---
## 2. What beni emits today, and why it decides the answer

Every strategy in §4 is a claim about what the compiler can emit. So the first thing to establish is
what it emits now. The probe is a real build, not a reading of
[`backend.md`](../backend.md) §4.

`beniapp/Bench.beni`, built with `beni build Bench.beni --library --platform=node`, gives this — all
of it copied verbatim from `out/Bench.mjs`:

```js
const Bench$mkRow  = (i$1, s$2) => ({ id: i$1, label: s$2 });          // a record
const Bench$relabel = (r$1, s$2) => ({ ...r$1, label: s$2 });          // a record UPDATE
const Bench$rows = { $: 1, a: Bench$mkRow(1, "a"),
                     b: { $: 1, a: Bench$mkRow(2, "b"),
                          b: { $: 0, a: null, b: null } } };           // a list
//                         a Msg:  { $: "Select", a: 3 }
```

Four facts follow, and all four are load-bearing.

**1. A record is a plain object with its keys in a canonical sorted order.** One hidden class per
record type. Field reads are monomorphic. Nothing to do here.

**2. A record update is a spread — `{...r, label: s}` — so it allocates a NEW object and leaves
every untouched field pointing at the same value.** This is what makes `===` on a row mean "deeply
unchanged". It is also, as R24 §6.8 already noted, *nowhere promised*: `language.md` does not
guarantee reference identity, and the rendering strategies in §4 depend on it. That is
question **F4**.

**3. A `List` is a cons list: `{$:1, a: head, b: tail}`, closed by the padded singleton
`{$:0, a:null, b:null}`.** `core/List.js` states the contract in its own header. There is no
indexed read, no `Array`, no vector; `core/` ships `List`, `Dict` (a balanced tree ordered by
`compare`), `Set`, `String`, `Char`, `Maybe`, `Result`, `Int32`, `Basics`. `backend.md` §4 parks the
question — *"cons cells …, pending M3c's benchmark of a vector trie"* — and §10's *Lists and strings
are the two representation questions §14 left open* promises exactly this measurement. §10 of this
report is it.

**4. A custom type is `{$: "Tag", a: payload}`, padded to one shape per type**, and a type all of
whose constructors are nullary is a bare tag string. A `Msg` therefore costs one small object per
message, which is nothing.

### 2.1 The `update` the compiler actually produced

The model half of the benchmark was written in beni (`beniapp/Bench.beni`, 103 lines, reproduced in
full in Appendix A) and compiled. This is the emitted `update`, unedited:

```js
const Bench$update = (msg$1, model$2) => {
  switch (msg$1.$) {
    case "Replace": { const rows$3 = msg$1.a; return { rows: rows$3, selected: 0 }; }
    case "Append":  { const rows$4 = msg$1.a;
                      return { ...model$2, rows: List$append(model$2.rows, rows$4) }; }
    case "UpdateEvery10":
      return { ...model$2, rows: List$indexedMap(model$2.rows, (i$5, r$6) =>
        Basics$remainderBy(i$5, 10) === 0
          ? { ...r$6, label: Basics$append(r$6.label, " !!!") } : r$6) };
    case "Clear":   return { rows: { $: 0, a: null, b: null }, selected: 0 };
    case "Swap":
      if (List$length(model$2.rows) < 999) { return model$2; }
      else {
        const a$7 = Bench$at(model$2.rows, 1);          // drop 1  |> head
        const b$8 = Bench$at(model$2.rows, 998);        // drop 998 |> head
        return { ...model$2, rows: List$indexedMap(model$2.rows, (i$9, r$10) =>
          i$9 === 1 ? b$8 : (i$9 === 998 ? a$7 : r$10)) };
      }
    case "Select":  { const id$11 = msg$1.a; return { ...model$2, selected: id$11 }; }
    default:        { const id$12 = msg$1.a;
                      return { ...model$2, rows: List$filter(model$2.rows, (r) => r.id !== id$12) }; }
  }
};
```

This is idiomatic, readable, and every line of it is what a beni programmer would write. It is also
the reason §10 exists: `Swap` walks the list three times and rebuilds the whole spine, and there is
no other way to write it, because `List` has no indexed read.

Two further observations from the same build, recorded because they will matter to whoever writes
the browser platform:

* **Derivation is eager and it reached the wire.** `Bench.mjs` exports `Bench$Msg$$eq` and
  `Bench$Msg$$compare`, derived for `Msg` although the program calls neither. `Reach.zig` keeps them
  because `--library` roots the build at its exported surface. In an application build they would go.
* **The compiled `core` a browser page needs for this model is six files, 17 290 bytes raw, and none of
  them mention the platform.** `out/core/{Basics,List,String}.mjs` plus their `.foreign.mjs`
  siblings; `grep -rn "platform/" out/core/*.mjs` is empty. That is R26 §8.1's finding again from the
  other side: the compiled core is already browser-ready.

---
## 3. The program every prototype implements — proposed beni source

This is the source a beni compiler would see. **It is proposed, not specified**: the JSX grammar is
[report 28](28-jsx-in-beni.md)'s subject and nothing here settles it. It is printed because every
claim in §4 about "what the compiler knows" is a claim about what it can read off *this*.

```elm
-- PROPOSED SYNTAX — report 28 owns the grammar.
type alias Row =
    { id : Int, label : String }


type alias Model =
    { rows : List Row, selected : Int }


type Msg
    = Replace (List Row)
    | Append (List Row)
    | UpdateEvery10
    | Clear
    | Swap
    | Select Int
    | Remove Int


update : sync Msg, Model -> Model
update msg model =
    case msg of
        Select id ->
            { model | selected = id }

        Remove id ->
            { model | rows = model.rows |> List.filter (\r -> r.id /= id) }

        -- …the rest is §2.1's, unchanged


view : sync Model -> Html Msg
view model =
    <tbody>
        { model.rows
            |> List.map
                (\row ->
                    <tr key={row.id} class={if row.id == model.selected then "danger" else ""}>
                        <td class="col-md-1">{String.fromInt row.id}</td>
                        <td class="col-md-4"><a onClick={Select row.id}>{row.label}</a></td>
                        <td class="col-md-1">
                            <a onClick={Remove row.id}>
                                <span class="glyphicon glyphicon-remove" aria-hidden="true"/>
                            </a>
                        </td>
                        <td class="col-md-6"/>
                    </tr>
                )
        }
    </tbody>
```

What a compiler can read off that source, ranked by how much analysis each fact costs — these are
the four rungs the prototypes climb:

| # | Fact | What it costs the compiler | Which prototype needs it |
|---|---|---|---|
| 0 | `view` is a function of `Model` | nothing | P1 |
| 1 | the markup is **static except at the braces**, so the `<tr>` is one `<template>` and three holes at known paths | the parser already has the tree; this is a walk | P2, P3 |
| 2 | every value is **immutable**, so `===` on a hole's input means "deeply unchanged" | nothing at compile time; it is a language property (§2, fact 2) | P2, P3 |
| 3 | each hole reads a known **set of model fields** — the list hole reads `rows`, the class hole reads `selected` — so a field-level diff of `update`'s result selects the holes to run | a per-hole free-variable analysis over the view body, which is an ordinary use-def walk | P3 |
| 4 | `class={if row.id == model.selected then …}` is an **equality-keyed selector** on `selected`, so `Select` can be O(1) instead of O(rows) | pattern-recognising `x == model.f` inside a list hole and emitting a key→instance index; this is `createSelector`, written by the compiler instead of by hand | P3's fast `Select` only |

Rung 4 is the only one that is a *pattern match on source shape* rather than a general analysis, and
it is the one this report is most sceptical of. §7.2 measures both halves: P3 with it, and
`p3-nosel` without it.

---

## 4. The subjects

Nineteen pages, all serving the same `index.html` skeleton (six buttons with the official ids and an
empty `<tbody>`) and the same `/css/currentStyle.css`.

### 4.1 Frameworks, from the benchmark repo

`vanillajs`, `vanillajs-3`, `vanillajs-lite` (three keyed vanilla variants — §5 reports which is
fastest), `solid` 1.9.3, `svelte` 5.42.1, `ivi` 5.1.0, `inferno` 8.2.2, `react-hooks` (React 19),
`blockdom` 0.9.26, `elm` 0.19.
All built with each framework's own `build-prod`, unmodified.

**Not built, and why.** `leptos` needs a Rust + `wasm-bindgen` toolchain and was out of the
30-minute budget the brief set; it is absent. `million` has no keyed entry in this revision of the
benchmark repo. Both are listed in §14.

### 4.2 Solid 2 — the bar

There is no `solid-next` entry in the benchmark repo, so the app was ported. Three things change
from 1.9, all of them read out of the vendored source and docs at `references/solid`
(`packages/solid/src/index.ts`'s *Not Implemented* block, and
`documentation/solid-2.0/04-stores.md`):

* `batch` is gone — writes auto-batch and `flush` forces;
* `createSelector` is gone, and its replacement is `createProjection`, for which the 2.0
  documentation gives precisely this pattern under the heading *"Selection without notifying every
  row"*;
* `<For>` is keyed by identity by default, and takes a `keyed: (item) => key` function.

The port, in full — `solid2/src/main.jsx`, minus the three word lists:

```jsx
import { createSignal, createProjection } from "solid-js";
import { render } from "@solidjs/web";
// …adjectives / colors / nouns / random / nextId as in the 1.9 app…

const Button = ([id, text, fn]) => (
  <div class="col-sm-6 smallpad">
    <button prop:id={id} class="btn btn-primary btn-block" type="button" onClick={fn}>{text}</button>
  </div>
);

render(() => {
  const [data, setData] = createSignal([]);
  const [selected, setSelected] = createSignal(null);
  const run = () => setData(buildData(1_000));
  const runLots = () => setData(buildData(10_000));
  const add = () => setData((d) => [...d, ...buildData(1_000)]);
  const update = () => { for (let i = 0, d = data(), len = d.length; i < len; i += 10)
                           d[i].setLabel((l) => l + " !!!"); };          // no `batch` in 2.0
  const clear = () => setData([]);
  const swapRows = () => { const list = data().slice();
    if (list.length > 998) { const t = list[1]; list[1] = list[998]; list[998] = t; setData(list); } };
  const isSel = createProjection((s) => {                                 // 2.0's createSelector
    const id = selected();
    if (s._prev != null) delete s[s._prev];
    if (id != null) s[id] = true;
    s._prev = id;
  }, {});
  return (
    <div class="container">
      {/* …the jumbotron and six Buttons… */}
      <table class="table table-hover table-striped test-data"><tbody>
        <For each={data()}>{(row) => {
          const rowId = row.id;
          return (
            <tr class={isSel[rowId] ? "danger" : ""}>
              <td class="col-md-1" textContent={rowId} />
              <td class="col-md-4"><a onClick={() => setSelected(rowId)} textContent={row.label()} /></td>
              <td class="col-md-1"><a onClick={() => setData((d) =>
                    d.toSpliced(d.findIndex((x) => x.id === rowId), 1))}>
                <span class="glyphicon glyphicon-remove" aria-hidden="true" /></a></td>
              <td class="col-md-6" />
            </tr>);
        }}</For>
      </tbody></table>
      <span class="preloadicon glyphicon glyphicon-remove" aria-hidden="true" />
    </div>);
}, document.getElementById("main"));
```

Built with `@solidjs/vite-plugin@3.0.0-next.35` on Vite 8 + terser, production conditions
(`Solid$$`, `installConsoleFooter` and the dev diagnostics are all absent from the bundle — checked).

### 4.3 The prototypes

Eight pages, all of them The Elm Architecture: one immutable model `{ rows, selected }`, messages,
a pure total `update` returning a **new** model with structural sharing, and a delegated click
listener on the `<tbody>` — which is what a compiler that sees the markup would emit, and what
`dom-expressions` does. Each is one ES module built by `build-proto.mjs` from `proto/common.js` plus
one strategy file, and the whole of each strategy file is reproduced in §6–§8.

| Page | Strategy | `rows` held as |
|---|---|---|
| `p1-vdom` | virtual DOM, keyed diff | JS array, copy-on-write |
| `p1-vdom-lazy` | the same, with Elm's `lazy` on every row | JS array |
| `p2-tpl` | compiled templates, top-down re-run, per-hole `===` | JS array |
| `p2-tpl-cons` | the same, over **beni's `List`** and **beni's compiled `update`** | cons cells |
| `p3-fields` | templates + compiler-derived field dependencies + the keyed selector | JS array |
| `p3-nosel` | the same **without** the selector recognition | JS array |
| `p3-fields-cons` | P3 over beni's `List` and beni's compiled `update` | cons cells |
| `p4-signals` | Solid 2's reactive runtime underneath, TEA on top | JS array |

**These are report 27 §0.5's three strategies, built.** Its **(A) signals as the programming
model** is `solid`/`solid2` here; its **(B) TEA plus compiled templates plus per-hole
reference-equality checks** is `p2-tpl`; its **(C) TEA outside, a compiler-derived dependency graph
inside** is `p3-fields`. `p1-vdom` is the strategy W1's rider assumed and report 27 does not list,
and `p4-signals` is the hybrid neither report names: (B)'s programming model over (A)'s runtime.
Report 27 §11 S1 recommends (B) with (C) held open, and says *"report 29 is built to test this and
should be believed over this paragraph"*. §0.3 is the answer.

The three `-cons` pages import `Bench$update` and `Bench$empty` **from the real compiler's output**;
nothing in their model half is hand-written JavaScript.

Two honest notes about what "as a compiler would emit" means here. First, the prototypes are
hand-written, so they are an *upper bound on what a compiler could reach*, not a lower bound: a real
emitter would be at best this good. Second, each strategy file says at the top which of §3's rungs
it presumes, and nothing in it uses knowledge the compiler would not have — in particular no
prototype special-cases an operation, and all eight run the same `update`.

---
## 5. The table benchmark, measured

### 5.1 How to read these tables

Nine operations, nineteen subjects, ten iterations each, official throttling, median milliseconds
**click to paint** from the trace. Three tables: `total`, then the `script` and `paint` halves of
it. The `geo` column is the official normalisation — per benchmark, the ratio to the fastest
subject, geometric mean across the nine; `vs van` is the same thing against `vanillajs` instead,
because that is the number the published table's readers quote. `vs van, script` is the geometric
mean of the script ratios, which §1.5 argues is the comparable column on this machine.

**Read the script table first.** Headless software rasterisation roughly doubles every paint
(§1.5), and paint is 70–95 % of most of these operations' totals, so the `total` table compresses
the differences between subjects. It is published because it is what the official benchmark
publishes and because §5.2's ranking check needs it.

### 5.2 The ranking, and the harness check

`out/cpu-throttled.json`, Chrome 153.0.8010.47 headless, n = 10, official throttling, 1-minute load
average 0.40–1.49 per batch. **Median total, click to paint, milliseconds.**

| subject | create 1k | replace 1k | update 10th | select | swap | remove | create 10k | append 1k | clear | geo | vs van | vs van, script |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs-lite | 38.54 | 45.48 | 22.01 | 4.38 | 27.30 | 23.31 | 496.25 | 46.30 | 19.21 | **1.007** | 0.984 | 0.536 |
| vanillajs | 40.92 | 46.86 | 21.80 | 4.86 | 27.13 | 23.50 | 496.32 | 46.02 | 18.53 | 1.024 | 1.000 | 1.000 |
| vanillajs-3 | 40.01 | 45.72 | 22.66 | 4.39 | 27.63 | 23.13 | 517.24 | 48.67 | 19.93 | 1.031 | 1.007 | 0.569 |
| **p3-nosel** | 40.86 | 47.26 | 23.29 | 4.93 | 27.45 | 23.59 | 520.63 | 48.00 | 19.26 | **1.050** | 1.026 | 1.051 |
| **p3-fields** | 41.33 | 47.59 | 23.56 | 4.57 | 28.30 | 23.46 | 520.20 | 47.72 | 20.44 | **1.054** | 1.030 | **0.989** |
| **p3-fields-cons** | 39.98 | 47.12 | 26.02 | 4.42 | 29.40 | 24.00 | 521.70 | 48.42 | 18.77 | **1.056** | 1.032 | 1.080 |
| **p2-tpl** | 41.09 | 47.03 | 23.51 | 5.65 | 28.13 | 23.48 | 517.88 | 47.73 | 19.10 | **1.068** | 1.043 | 1.143 |
| **p2-tpl-cons** | 40.42 | 46.50 | 25.72 | 5.56 | 28.63 | 23.13 | 520.38 | 47.95 | 18.59 | **1.071** | 1.047 | 1.198 |
| solid 1.9 | 42.30 | 49.67 | 26.61 | 5.42 | 28.89 | 23.90 | 524.29 | 48.11 | 19.54 | 1.098 | 1.073 | 1.322 |
| blockdom | 42.69 | 49.51 | 26.23 | 6.16 | 29.82 | 23.48 | 524.04 | 47.78 | 18.51 | 1.107 | 1.081 | 1.290 |
| inferno | 42.83 | 50.75 | 26.34 | 6.48 | 29.55 | 23.77 | 541.48 | 49.97 | 20.88 | 1.142 | 1.116 | 1.572 |
| ivi | 41.29 | 50.16 | 26.54 | 7.00 | 30.20 | 23.52 | 532.99 | 49.34 | 23.29 | 1.159 | 1.132 | 1.544 |
| **p1-vdom-lazy** | 44.34 | 50.61 | 26.07 | 6.75 | 28.93 | 23.97 | 538.51 | 49.16 | 23.19 | **1.159** | 1.133 | 1.323 |
| **Solid 2.0.0-rc.9** | **42.95** | **51.22** | **28.41** | **7.20** | **30.67** | **24.04** | **531.64** | **49.93** | **20.33** | **1.168** | **1.141** | **1.767** |
| **p4-signals** | 43.53 | 50.44 | 28.21 | 7.24 | 30.38 | 24.37 | 531.13 | 49.38 | 20.67 | **1.168** | 1.141 | 1.828 |
| svelte 5 | 42.59 | 51.54 | 26.48 | 8.47 | 31.14 | 24.81 | 530.50 | 49.75 | 20.48 | 1.186 | 1.158 | 1.788 |
| **p1-vdom** | 43.16 | 51.00 | 28.52 | 9.79 | 31.22 | 24.30 | 543.45 | 50.44 | 22.70 | **1.232** | 1.203 | 2.336 |
| elm 0.19 | 49.08 | 58.20 | 38.88 | 8.64 | 41.13 | 32.66 | 583.12 | 61.98 | 23.24 | 1.426 | 1.393 | 2.708 |
| react-hooks 19 | 47.65 | 58.67 | 29.69 | 9.93 | 193.07 | 23.98 | 748.19 | 53.97 | 31.73 | 1.686 | 1.647 | 4.829 |

**The harness agrees with the published table.** Against the official `results.json` (Chrome 152),
restricted to the ten subjects both have, the two orderings are:

| | order by geometric mean |
|---|---|
| **official** | vanillajs-lite, vanillajs-3, vanillajs, blockdom, inferno, solid, ivi, svelte, elm, react-hooks |
| **here** | vanillajs-lite, vanillajs, vanillajs-3, solid, blockdom, inferno, ivi, svelte, elm, react-hooks |

Two adjacent pairs swap — `vanillajs`/`vanillajs-3` (0.007 apart officially, 0.007 apart here) and
`solid`/`blockdom` (0.055 apart officially, 0.009 here) — and nothing else moves. The clusters, the
order between clusters, and the two outliers are identical. The strongest single check is
**react-hooks's swap pathology**: the official table has it at 89.9 ms against everyone else's
11–15, and this harness has it at 193.07 against everyone else's 27–31, with 32.35 ms of script and
158.19 ms of paint. A harness that invented its numbers would not reproduce a framework-specific
outlier of that shape.

The *magnitudes* are compressed here — react-hooks is 1.647× vanilla against the official 1.816×,
elm 1.393× against 1.635× — and the reason is §1.5's: headless doubles the paint, every subject pays
the same doubled paint, and a ratio with a large common term in it moves toward 1. That is also why
the `vs van, script` column exists.

### 5.3 Spread

Standard deviation of the ten measured iterations, in milliseconds, worst case per subject across the
nine benchmarks: `p2-tpl-cons` 1.72, `p3-fields` 3.84, `solid` 2.37, `solid2` 3.32, `p1-vdom` 2.38,
`elm` 5.68, `react-hooks` 8.79 (its swap). The large ones are all on `select`, where the median is
4–10 ms and a single missed frame is 16 ms; on `create 10k` the sd is 4–13 ms against medians of
500. **No two adjacent rows of §5.2's ranking are separated by more than their spread**, which is
why the verdict in §0 is argued on the script column and on the per-operation asymptotics in
§6–§8, not on the geometric mean alone.

### 5.4 The script column, which is where the question lives

Median script milliseconds, same runs. Paint is omitted because it is within ±8 % across every
subject for every benchmark except react's swap — every implementation asks Chrome to lay out the
same table.

| subject | create 1k | replace 1k | update 10th | select | swap | remove | create 10k | append 1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| vanillajs-lite | 2.01 | 5.89 | 0.80 | 0.15 | 0.26 | 0.08 | 22.40 | 1.99 | 16.03 |
| vanillajs-3 | 2.23 | 6.21 | 0.52 | 0.16 | 0.46 | 0.08 | 24.09 | 2.16 | 16.45 |
| vanillajs | 2.49 | 6.22 | 0.89 | 1.04 | 0.57 | 0.49 | 30.89 | 2.85 | 16.44 |
| **p3-fields** | 2.52 | 7.06 | 1.20 | **0.49** | 0.77 | 0.47 | 29.34 | 2.69 | 17.55 |
| **p3-nosel** | 2.45 | 6.97 | 1.10 | 0.96 | 0.77 | 0.48 | 30.02 | 2.69 | 16.88 |
| **p3-fields-cons** | 2.40 | 6.97 | 1.27 | 0.72 | 1.05 | 0.50 | 30.97 | 2.83 | 16.41 |
| **p2-tpl** | 2.45 | 7.00 | 1.08 | 1.71 | 0.88 | 0.51 | 30.06 | 2.70 | 16.76 |
| **p2-tpl-cons** | 2.43 | 6.88 | 1.48 | 1.68 | 0.98 | 0.51 | 29.70 | 2.89 | 16.48 |
| solid 1.9 | 3.02 | 8.18 | 1.56 | 1.38 | 1.19 | 0.45 | 40.79 | 3.53 | 17.39 |
| blockdom | 3.27 | 8.36 | 1.47 | 1.71 | 0.79 | 0.42 | 42.27 | 3.62 | 16.44 |
| ivi | 3.15 | 8.27 | 1.98 | 2.75 | 1.23 | 0.56 | 40.66 | 3.47 | 20.91 |
| inferno | 4.02 | 8.57 | 1.73 | 2.16 | 1.14 | 0.48 | 53.46 | 4.86 | 18.51 |
| **p1-vdom-lazy** | 4.01 | 9.02 | 1.10 | 2.31 | **0.44** | **0.37** | 52.63 | 4.37 | 20.89 |
| **Solid 2** | **3.88** | **9.17** | **2.35** | **2.60** | **1.29** | **0.83** | **50.98** | **4.55** | **18.04** |
| svelte 5 | 3.67 | 9.59 | 1.79 | 3.94 | 1.65 | 0.69 | 49.97 | 4.21 | 18.25 |
| **p4-signals** | 4.01 | 9.30 | 2.78 | 2.88 | 1.75 | 0.57 | 50.58 | 4.75 | 18.42 |
| **p1-vdom** | 3.98 | 8.98 | 3.55 | **5.64** | 2.52 | 1.04 | 54.89 | 5.72 | 20.41 |
| elm 0.19 | 6.81 | 11.66 | 4.11 | 4.05 | 2.11 | 1.04 | 89.88 | 8.58 | 20.32 |
| react-hooks 19 | 7.80 | 16.34 | 4.41 | 5.53 | 32.35 | 1.31 | 249.12 | 8.60 | 29.30 |

**Read the `select` column.** It is the operation that separates the strategies, because it is the
one where the model changes by one integer and the screen changes in two places: P3 with the keyed
selector **0.49 ms**, P3 without it 0.96, P2 1.71, Solid 1.9 1.38, Solid 2 **2.60**, the virtual DOM
**5.64**, Elm 4.05. And `clear` is the operation where they all coincide — 16–21 ms of which
almost none is paint, because it is Chrome tearing down 1 000 `<tr>`s and nobody escapes it.

### 5.5 The one number that frames everything else

Add the paint column up. On `create 1k`, every subject's paint is **36–39 ms** and the whole spread
of script is **2.0–7.8 ms**. On `create 10k`, paint is **459–493 ms** and script **22–249**. On
`update 10th`, paint is 19–24 and script 0.5–4.4. On `swap`, paint 25–28 and script 0.26–2.5
(react's 158/32 excepted).

**So on seven of the nine operations, the difference between the best renderer measured and the
worst sensible one is smaller than the paint every one of them pays.** This is R27 §10.4's finding
reproduced from the other side, and R27 states the consequence better than this report can: *"On a
real DOM the framework's share of an update is 2–15 % of the operation. An architecture 2× slower
than Solid in its own layer is 2–15 % slower end to end."*

The two operations where that is *not* true are `clear` (all script, no paint) and `select` (0.15 to
5.64 ms of script against 3 ms of paint). Those are the two the rest of this report is about.

### 5.6 Where the time went inside the prototypes

The prototypes record `performance.now()` around `update` and around `render`, reset immediately
before the measured click. Median milliseconds, `update / render`:

| subject | create 1k | replace 1k | update 10th | select | swap | remove | create 10k | append 1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| p3-fields | 0.01 / 2.35 | 0.00 / 6.90 | 0.01 / 0.84 | 0.01 / **0.03** | 0.01 / 0.58 | 0.02 / 0.37 | 0.01 / 27.70 | 0.01 / 2.53 | 0.01 / 16.85 |
| p3-nosel | 0.01 / 2.31 | 0.00 / 6.83 | 0.01 / 0.81 | 0.01 / **0.27** | 0.01 / 0.55 | 0.02 / 0.39 | 0.01 / 28.30 | 0.01 / 2.52 | 0.01 / 16.70 |
| p3-fields-cons | 0.01 / 2.26 | 0.00 / 6.85 | **0.21** / 0.93 | 0.00 / 0.03 | **0.43** / 0.50 | 0.05 / 0.39 | 0.01 / 29.23 | **0.17** / 2.53 | 0.01 / 16.09 |
| p2-tpl | 0.01 / 2.29 | 0.01 / 6.83 | 0.01 / 0.91 | 0.01 / **1.30** | 0.01 / 0.57 | 0.03 / 0.29 | 0.01 / 28.11 | 0.01 / 2.52 | 0.01 / 16.30 |
| p2-tpl-cons | 0.01 / 2.29 | 0.00 / 6.75 | **0.16** / 0.95 | 0.01 / 1.20 | 0.07 / 0.77 | 0.04 / 0.41 | 0.01 / 27.92 | **0.17** / 2.59 | 0.01 / 16.44 |
| p1-vdom-lazy | 0.01 / 3.88 | 0.00 / 8.86 | 0.01 / 1.01 | 0.01 / 1.77 | 0.01 / 0.19 | 0.01 / 0.08 | 0.01 / 51.69 | 0.01 / 4.20 | 0.01 / 20.52 |
| p1-vdom | 0.01 / 3.83 | 0.01 / 8.84 | 0.01 / 3.33 | 0.01 / **4.75** | 0.01 / 2.39 | 0.01 / 0.94 | 0.01 / 53.96 | 0.01 / 5.55 | 0.01 / 20.02 |
| p4-signals | 0.01 / 0.01 | 0.00 / 0.05 | 0.01 / 0.01 | 0.01 / 0.67 | 0.01 / 0.01 | 0.03 / 0.01 | 0.01 / 0.01 | 0.01 / 0.01 | 0.00 / 0.01 |

Four things fall out of that table and each of them is a finding.

**1. With `rows` as an array, `update` is free — 0.00–0.03 ms on every operation.** The whole cost
of a message is rendering. Nobody should spend an hour optimising a beni `update`.

**2. With `rows` as beni's `List`, `update` is not free, and the numbers say exactly where.**
`UpdateEvery10` 0.21 ms, `Swap` 0.43 ms, `Append` 0.17 ms, against 0.01 for the array. That is a
**20–40× increase on the model half** — and it is 0.4 ms against a 28 ms operation, so it does not
show up in §5.2's totals. §10 measures it properly, at 10 000 rows as well.

**3. P3's `Select` is 43× cheaper than P2's** — 0.03 ms against 1.30 — and P3-without-the-selector
sits between them at 0.27. So the split is: **0.03 ms is two map lookups and two `className` writes;
0.27 ms is walking 1 000 instances and comparing; 1.30 ms is walking 1 000 instances *while
rebuilding the key→instance map and the node array*.** Most of P2's `Select` cost is not the
reference comparison at all — it is the keyed-reconciliation bookkeeping that runs because P2 does
not know `rows` is unchanged.

**4. `p4-signals`'s 0.01 ms is not a result, it is an artefact, and it has to be said.** Solid 2
batches writes and flushes on a **microtask** (R27 §3.1), so `dispatch` returns before any DOM work
happens and the in-page split cannot see it. P4's real cost is in §5.4's trace-based script column —
2.78 ms on `update 10th`, 2.88 on `select` — where it is indistinguishable from Solid 2's own
2.35/2.60, which is what one would expect of the same runtime.

---

### 5.7 Unthrottled, and why the official benchmark throttles

The same three operations the official benchmark slows 4× — `update 10th`, `select`, `swap` — run
again at 1×, n = 10, load 0.71. **The `total` column becomes unusable and the `script` column does
not.**

Unthrottled, these operations take 2–18 ms, which is the same order as a frame; the standard
deviation of the ten iterations is **2.1–5.0 ms on every subject**, and the resulting ranking puts
`inferno` first, `vanillajs-3` twelfth and `p3-nosel` below `react-hooks`. That is not a measurement
of anything except when the next `Commit` happened to land. **This is the reason `benchmarksCommon.ts`
throttles exactly these three** (and `remove` at 2×, `clear` at 4×), and running them at 1× is a
useful demonstration of why rather than a second opinion.

The script column, which does not depend on frame boundaries, is clean and agrees with §5.4 divided
by roughly four:

| subject | update 10th | select | swap |
|---|--:|--:|--:|
| vanillajs-lite | 0.20 | 0.17 | 0.18 |
| vanillajs-3 | 0.24 | 0.17 | 0.18 |
| **p3-fields-cons** | 0.45 | **0.20** | 0.38 |
| **p3-fields** | **0.36** | **0.21** | 0.29 |
| vanillajs | 0.23 | 0.32 | 0.20 |
| **p3-nosel** | 0.37 | 0.29 | 0.29 |
| **p2-tpl** | 0.39 | 0.46 | 0.29 |
| **p2-tpl-cons** | 0.44 | 0.46 | 0.40 |
| solid 1.9 | 0.49 | 0.40 | 0.33 |
| blockdom | 0.41 | 0.54 | 0.27 |
| **p1-vdom-lazy** | 0.42 | 0.65 | **0.27** |
| inferno | 0.53 | 0.68 | 0.38 |
| **Solid 2** | **0.69** | **0.78** | **0.39** |
| ivi | 0.55 | 0.79 | 0.38 |
| **p4-signals** | 0.68 | 0.81 | 0.52 |
| elm | 1.10 | 1.17 | 0.62 |
| svelte | 0.53 | 1.23 | 0.48 |
| react-hooks | 1.14 | 1.61 | 7.25 |
| **p1-vdom** | 0.85 | **1.87** | 0.57 |

P3's `select` is **3.7× Solid 2's** unthrottled (0.21 against 0.78) where it was 5.3× throttled;
P2's is 1.7× (0.46 against 0.78) where it was 1.5×. The ordering is the same, the ratios move by
less than 30 %, and the conclusion does not change.

---

## 6. P1 — the virtual DOM, and what it costs

### 6.1 What it is

`view` builds a vnode tree from the model on every message; a keyed diff turns last frame's tree
into this frame's. This is the strategy W1's rider assumed, and the one that asks least of the
compiler: rung 0 only.

The diff is **snabbdom's** — a four-pointer pass over the children (old-start, old-end, new-start,
new-end) with a key→index map for the otherwise case. That is the algorithm ivi, Inferno and Vue 2
use. It is deliberately *not* Elm's: R24 §6.5 establishes that Elm's is a single forward pass with
**one** element of lookahead, so "swap rows 1 and 998" falls to its `break` path. Choosing
snabbdom's makes P1 the *most favourable* vdom, not a straw man.

The whole of `proto/p1-vdom.js`'s diff, 40 lines:

```js
function patch(o, n) {
  const el = (n.e = o.e);
  if (o.t === "$lazy" && n.t === "$lazy") {
    if (o.f === n.f && refsEq(o.r, n.r)) { n.v = o.v; return; }   // the whole subtree is skipped
    patch(force(o), force(n)); n.e = force(n).e; return;
  }
  if (o.t !== n.t) { const fresh = create(n); el.parentNode.replaceChild(fresh, el); return; }
  if (n.t === null) { if (o.c !== n.c) el.nodeValue = n.c; return; }
  patchAttrs(el, o.a, n.a);
  patchChildren(el, o.c || [], n.c || []);
}

function patchChildren(parent, oc, nc) {
  let os = 0, oe = oc.length - 1, ns = 0, ne = nc.length - 1;
  let osv = oc[0], oev = oc[oe], nsv = nc[0], nev = nc[ne], map = null;
  while (os <= oe && ns <= ne) {
    if (osv === undefined) { osv = oc[++os]; }
    else if (oev === undefined) { oev = oc[--oe]; }
    else if (same(osv, nsv)) { patch(osv, nsv); osv = oc[++os]; nsv = nc[++ns]; }
    else if (same(oev, nev)) { patch(oev, nev); oev = oc[--oe]; nev = nc[--ne]; }
    else if (same(osv, nev)) { patch(osv, nev); parent.insertBefore(osv.e, oev.e.nextSibling);
                               osv = oc[++os]; nev = nc[--ne]; }
    else if (same(oev, nsv)) { patch(oev, nsv); parent.insertBefore(oev.e, osv.e);
                               oev = oc[--oe]; nsv = nc[++ns]; }
    else {
      if (!map) { map = new Map();
                  for (let i = os; i <= oe; i++) if (oc[i] && oc[i].k != null) map.set(oc[i].k, i); }
      const idx = map.get(nsv.k);
      if (idx === undefined) { parent.insertBefore(create(nsv), osv.e); }
      else { const ov = oc[idx]; patch(ov, nsv); oc[idx] = undefined; parent.insertBefore(ov.e, osv.e); }
      nsv = nc[++ns];
    }
  }
  if (os > oe) { const before = nc[ne + 1] ? nc[ne + 1].e : null;
                 for (; ns <= ne; ns++) parent.insertBefore(create(nc[ns]), before); }
  else if (ns > ne) { for (; os <= oe; os++) if (oc[os]) oc[os].e.remove(); }
}
const same = (a, b) => a.t === b.t && a.k === b.k;
```

and the view the compiler would emit from §3's JSX:

```js
const TD6 = { class: "col-md-6" }, TD1 = { class: "col-md-1" }, TD4 = { class: "col-md-4" };
const GLYPH = { class: "glyphicon glyphicon-remove", "aria-hidden": "true" };
const ROW_SEL = { class: "danger" }, ROW_PLAIN = { class: "" };

function viewRow(row, selected) {
  return h("tr", row.id === selected ? ROW_SEL : ROW_PLAIN, [
    h("td", TD1, [T(String(row.id))]),
    h("td", TD4, [h("a", null, [T(row.label)])]),
    h("td", TD1, [h("a", null, [h("span", GLYPH, [])])]),
    h("td", TD6, []),
  ], row.id);
}
```

Note that even here the compiler is helping: the five attribute objects are **hoisted constants**,
because it can see they are literal. A hand-written vdom app allocates five objects per row per
render; this one allocates none. That is worth saying because it means the P1 numbers are not an
argument against vdoms in general — they are the best case for one.

`p1-vdom-lazy` adds Elm's thunk, in the form that works:

```js
function L(f, r, k) { return { t: "$lazy", f, r, k, v: null, e: null }; }
function viewRowL(row, sel) { return viewRow(row, sel ? row.id : -1); }
// refs are [row, row.id === selected] — a Bool, NOT `selected` itself, so a
// selection change moves the refs of exactly two rows instead of all of them.
out[i] = L(viewRowL, [rows[i], rows[i].id === selected], rows[i].id);
```

R24 §6.8's warning applies in full: written the obvious way — `lazy2 viewRow row model.selected` —
`lazy` buys **nothing** on `Select`, because `selected` is one of the refs and it changed. The
version above is the one an experienced Elm programmer writes, and it is what is measured.

### 6.2 The asymptotic cost, per operation

| Operation | vnode allocations | `===` comparisons | DOM writes |
|---|---|---|---|
| `Select` | 9 per row × 1 000 = **9 000** (P1) / 1 thunk per row = **1 000** (P1L) | the whole tree (P1) / 1 000 ref pairs (P1L) | 2 `class` writes |
| `UpdateEvery10` | 9 000 / 1 000 | whole tree / 1 000 | 100 `nodeValue` writes |
| `Swap` | 9 000 / 1 000 | whole tree / 1 000 | 2 `insertBefore` |
| `Remove` | 8 991 / 999 | whole tree / 999 | 1 `remove` |

The row that decides everything is `Select`: a vdom must **rebuild the view of every row to
discover that 998 of them did not change**, and `lazy` reduces that from nine allocations per row to
one but does not remove the O(rows) walk. That is the asymptotic fact; §5 is how much it costs in
milliseconds.

---

### 6.3 What it measures

Geometric mean against vanillajs, script only: **P1 2.336, P1 with `lazy` 1.323**. Solid 2 is 1.767,
Solid 1.9 1.322, Elm 2.708.

Two results, and they point in opposite directions.

**A keyed virtual DOM is not slow in the abstract.** On `swap`, `remove` and `update 10th`,
`p1-vdom-lazy` is at or ahead of Solid 2: 0.44 against 1.29 ms of script on swap, 0.37 against 0.83
on remove, 1.10 against 2.35 on update-10th. On the structural operations a keyed diff is doing the
same work every keyed reconciler does, and its thunks make the rebuild cheap.

**But `select` is where it breaks, and it breaks for a reason no tuning removes.** `p1-vdom` spends
**5.64 ms of script** on select — the worst of any subject except react-hooks — against P3's 0.49 and
Solid 2's 2.60. The in-page split (§5.6) puts 4.75 ms of that in `render`. What it is doing is
rebuilding 9 000 vnodes to discover that 998 rows did not change. `lazy` cuts it to 2.31 ms by
rebuilding 1 000 thunks instead of 9 000 vnodes — a 2.4× improvement, and still 4.7× P3.

**`lazy` earns its keep, and it costs exactly what R24 §6.8 says it costs.** 2.336 → 1.323 on the
geometric mean is the largest single improvement any change in this report produced. And it is only
that large because the thunk was written in the form that works —
`L(viewRowL, [row, row.id === selected], row.id)`. Written the obvious way,
`lazy2 viewRow row model.selected`, the second ref changes on every `Select` and `lazy` buys nothing
at all on the one operation it is needed for. That footgun is real, has no diagnostic in Elm, and
would have none in beni either.

So the honest summary of P1 is: **a good keyed virtual DOM with `lazy` lands at Solid 2's overall
number and behind Solid 1.9's, and it gets there by asking the programmer to annotate every list row
with a memoisation hint whose correct form is not obvious.** W4's recommendation — park `lazy`, do
not put a reference-identity guarantee into `language.md` for a performance feature — is
incompatible with shipping a virtual DOM that is competitive on `select`.

---
## 7. P2 and P3 — compiled templates

### 7.1 P2: top-down, per-hole `===`

P2 asks the compiler for rungs 1 and 2 of §3's table and nothing else. The row's markup becomes one
`<template>`; the holes are reached by the paths the compiler computed; the update function is
re-run from the root on every message and each hole compares its own input.

```js
const ROW_TPL = document.createElement("template");
ROW_TPL.innerHTML =
  '<tr><td class="col-md-1"> </td><td class="col-md-4"><a> </a></td>' +
  '<td class="col-md-1"><a><span class="glyphicon glyphicon-remove" aria-hidden="true"></span></a></td>' +
  '<td class="col-md-6"></td></tr>';
const ROW_PROTO = ROW_TPL.content.firstChild;

function makeRow(row, selected) {
  const el = ROW_PROTO.cloneNode(true);
  const tds = el.firstChild;
  const idT = tds.firstChild;                                   // hole path [0,0]
  const lbT = tds.nextSibling.firstChild.firstChild;            // hole path [1,0,0]
  idT.nodeValue = row.id;
  lbT.nodeValue = row.label;
  if (row.id === selected) el.className = "danger";
  el.__id = row.id;
  return { el, row, sel: row.id === selected, idT, lbT };
}

// The per-hole check. `row === inst.row` IS the strategy: in beni the row is
// immutable, so a reference-equal row cannot differ in any field.
function updateRow(inst, row, selected) {
  const sel = row.id === selected;
  if (inst.row !== row) {
    if (inst.row.label !== row.label) inst.lbT.nodeValue = row.label;
    if (inst.row.id !== row.id) inst.idT.nodeValue = row.id;
    inst.row = row;
  }
  if (inst.sel !== sel) { inst.el.className = sel ? "danger" : ""; inst.sel = sel; }
}
```

The list hole keeps **row instances**, not vnodes, in a `key → instance` map, and the DOM reorder is
`reconcileArrays`, adapted from `references/dom-expressions/packages/runtime/src/reconcile.js` —
itself WebReflection's `udomdiff` — with the `$$SLOT` ownership tags dropped, because this prototype
owns the whole `<tbody>` and every node in `a` is live. So P2 and Solid use *the same* array
reconciler; any difference between them is not the reconciler.

```js
function makeListHole(tbody) {
  let insts = new Map(), nodes = [];
  const hole = function run(rows, selected, mode) {
    const n = rows.length;
    if (n === 0) { if (nodes.length) { tbody.textContent = ""; insts = new Map(); nodes = []; } return; }
    const next = new Array(n), nextInsts = new Map();
    let moved = nodes.length !== n;
    for (let i = 0; i < n; i++) {
      const row = rows[i];
      let inst = insts.get(row.id);
      if (inst === undefined) { inst = makeRow(row, selected); moved = true; }
      else { if (mode === 1) updateRowNoSel(inst, row); else updateRow(inst, row, selected);
             insts.delete(row.id); }
      nextInsts.set(row.id, inst);
      next[i] = inst.el;
      if (!moved && nodes[i] !== inst.el) moved = true;
    }
    if (moved) {
      if (nodes.length === 0) { const f = document.createDocumentFragment();
                                for (let i = 0; i < n; i++) f.appendChild(next[i]); tbody.appendChild(f); }
      else reconcileArrays(tbody, nodes, next);   // it removes what `b` no longer holds
    }
    insts = nextInsts; nodes = next;
  };
  hole.insts = () => insts;
  return hole;
}
```

**Cost of a message under P2: O(rows) reference comparisons, one `Map` lookup per row, and zero
allocation for any row whose record did not change.** The `moved` flag means the reconciler is not
even entered when nothing moved, which is the common case for `Select` and `UpdateEvery10`.

### 7.2 P3: the compiler knows which fields each hole reads

P3 adds rung 3, and for its fast `Select`, rung 4.

```js
function mountP3(tbody, update, empty, mk, keyedSelector) {
  let model = empty, prev = null;
  const listHole = makeListHole(tbody);
  const render = (m) => {
    const rowsChanged = prev === null || ROWSRAW(m) !== ROWSRAW(prev);
    const selChanged  = prev === null || m.selected !== prev.selected;
    if (rowsChanged) listHole(ROWS(m), m.selected, selChanged ? 2 : 1);
    else if (selChanged) {
      if (keyedSelector) {                       // rung 4 — O(1)
        const insts = listHole.insts();
        const a = insts.get(prev.selected); if (a) { a.el.className = "";       a.sel = false; }
        const b = insts.get(m.selected);    if (b) { b.el.className = "danger"; b.sel = true;  }
      } else {                                   // rung 3 only — O(rows) compares, no allocation
        for (const inst of listHole.insts().values()) {
          const sel = inst.row.id === m.selected;
          if (inst.sel !== sel) { inst.el.className = sel ? "danger" : ""; inst.sel = sel; }
        }
      }
    }
    prev = m;
  };
  const dispatch = makeDispatch(update, render, () => model, (m) => { model = m; });
  wireButtons(dispatch, mk); wireTable(tbody, dispatch);
}
```

Two things to be honest about:

1. **`mode === 1` is a second, quieter win.** When `rows` changed but `selected` did not, the
   compiler knows the class hole cannot have moved, so `updateRowNoSel` drops one comparison and one
   branch per row. This is rung 3, not rung 4, and it applies to `UpdateEvery10`, `Swap`, `Append`
   and `Remove`.
2. **Rung 4 is the fragile one.** It requires the compiler to recognise
   `class={if row.id == model.selected then …}` as an equality-keyed selector *inside a list hole*
   and to maintain the key→instance index it already has for reconciliation. Solid has exactly this
   and makes the programmer write it (`createSelector` in 1.9, `createProjection` in 2.0). If the
   compiler cannot recognise the pattern, `Select` degrades to the `else` branch above — which is
   what `p3-nosel` measures, and the difference between the two is the price of the analysis.

---

### 7.3 What they measure

Geometric mean against vanillajs, **script only**: `p3-fields` **0.989**, `p3-nosel` 1.051,
`p3-fields-cons` 1.080, `p2-tpl` 1.143, `p2-tpl-cons` 1.198 — against Solid 1.9's 1.322 and
**Solid 2's 1.767**.

Per operation, against Solid 2's script, times faster (>1 means the prototype is faster):

| | create 1k | replace 1k | update 10th | select | swap | remove | create 10k | append 1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| p2-tpl vs Solid 2 | 1.58× | 1.31× | 2.18× | 1.52× | 1.47× | 1.63× | 1.70× | 1.69× | 1.08× |
| p3-fields vs Solid 2 | 1.54× | 1.30× | 1.96× | **5.31×** | 1.68× | 1.77× | 1.74× | 1.69× | 1.03× |
| p2-tpl vs Solid 1.9 | 1.23× | 1.17× | 1.44× | 0.81× | 1.35× | 0.88× | 1.36× | 1.31× | 1.04× |
| p3-fields vs Solid 1.9 | 1.20× | 1.16× | 1.30× | **2.82×** | 1.55× | 0.96× | 1.39× | 1.31× | 0.99× |

**P2 already beats Solid 2 on every operation, and is within 20 % of Solid 1.9 on the two where
Solid 1.9 is ahead.** The two are `select` (Solid 1.9's hand-written `createSelector` against P2's
O(rows) walk) and `remove` (0.45 against 0.51 ms — noise at this scale). Everything else P2 wins,
because it allocates nothing per unchanged row and Solid allocates a mapping array per list update.

**P3's whole contribution is `select`, and it is a 3.5× improvement there.** 1.71 → 0.49 ms of
script. The geometric mean moves 1.143 → 0.989, which is to say **P3 costs the same script as
hand-written keyed vanilla JavaScript across the nine operations**, and it does that while the
programmer writes one immutable model and a pure `update`.

### 7.4 What the improvement actually consists of — and it is not the `===`

§5.6's in-page split decomposes `select` at 1 000 rows, under 4× throttling:

| variant | what runs | in-page render |
|---|---|---|
| P3 with the keyed selector | 2 `Map.get`, 2 `className` writes | **0.03 ms** |
| P3 without it (`p3-nosel`) | iterate 1 000 instances, compare `inst.row.id === selected` and `inst.sel`, write 2 | **0.27 ms** |
| P2 | the same 1 000-instance walk **plus** rebuilding the key→instance map and the node array | **1.30 ms** |

Three separate costs, and the middle row is the interesting one. The *comparison* over 1 000 rows
costs 0.27 ms under 4× throttle — about **68 ns per row** unthrottled. R27 §5.5 measured a per-hole
reference-equality walk in Node at **0.93 ns per hole**, and both numbers are right: R27's walk is
`a[i] !== b[i]` over two dense arrays in a tight loop, and this one iterates a `Map`'s values and
touches three fields of an instance object before deciding. **The 1 ns figure is the floor of the
technique, not what a renderer pays**; a renderer that keeps its rows in a dense array indexed the
same way as the model would be nearer it.

And the largest term is neither: **1.03 of P2's 1.30 ms is the keyed-reconciliation bookkeeping**,
which runs only because P2 does not know that `rows` did not change. That is precisely the
information rung 3 supplies, and it is why `p3-nosel` — which has rung 3 but *not* the selector
recognition — already recovers four fifths of the gap. **Rung 4 is worth 0.24 ms of the 1.27; rung 3
is worth 1.03.**

This matters for F2. If the compiler can only manage the field-level diff and never learns to
recognise `x == model.f` as a selector, P3 still lands at a geometric mean of 1.051 against
vanillajs's 1.000 and Solid 2's 1.767. **Rung 4 is a refinement; rung 3 is the feature.**

### 7.5 What the `List` costs the renderer, separately from `update`

`p2-tpl-cons` and `p3-fields-cons` differ from their array twins in exactly two places: the model's
`update` is beni's compiled one over cons cells, and the list hole has to be handed an array.

* **P2 over cons pays the walk on every message**, because it re-runs top-down and calls
  `consToArray(m.rows)` each time: `select` in-page render 1.20 ms against P2-array's 1.30 (the walk
  is cheap next to the bookkeeping), but `update 10th` 0.95 against 0.91 and script 1.48 against 1.08.
* **P3 over cons pays it only when `rows` changed**, because the field diff tells it so: `select`
  in-page render **0.03 ms**, identical to P3-array. That is rung 3 paying for itself a second time,
  for a reason that has nothing to do with selectors.

The residue is the `update` half, and it is §10's subject.

---
## 8. P4 — Solid's runtime, Elm's programming model

The model, the messages and `update` are **byte for byte** P1/P2/P3's. The only difference is what
the platform does with the new model: it writes the two model fields into two signals and lets
Solid 2's `mapArray`, keyed by `id`, turn "this row record is a different object than last time"
into a per-row signal write.

```jsx
render(() => {
  let model = { rows: EMPTY_ARR, selected: 0 };
  const [rows, setRows] = createSignal(model.rows);
  const [selected, setSelected] = createSignal(model.selected);
  const dispatch = (msg) => {
    const m = update(msg, model);
    const prev = model; model = m;
    if (m.rows !== prev.rows)         setRows(m.rows);
    if (m.selected !== prev.selected) setSelected(m.selected);
  };
  const isSel = createProjection((s) => { const id = selected();
    if (s._prev != null) delete s[s._prev];
    if (id != null) s[id] = true; s._prev = id; }, {});
  return ( /* … */
    <For each={rows()} keyed={(r) => r.id}>
      {(row) => { const rowId = row().id; return (
        <tr class={isSel[rowId] ? "danger" : ""}>
          <td class="col-md-1" textContent={rowId} />
          <td class="col-md-4"><a onClick={() => dispatch({ $: "Select", a: rowId })}
                                  textContent={row().label} /></td>
          <td class="col-md-1"><a onClick={() => dispatch({ $: "Remove", a: rowId })}>
            <span class="glyphicon glyphicon-remove" aria-hidden="true" /></a></td>
          <td class="col-md-6" />
        </tr>); }}
    </For> /* … */ );
}, document.getElementById("main"));
```

`keyed={(r) => r.id}` is the whole trick: Solid's `mapArray` then delivers each row as an
**accessor** that fires when the row record changes identity, which is precisely the `inst.row !==
row` comparison P2 does by hand — done by `mapArray` instead. So P4 is *P2's comparison loop, plus a
reactive graph*, and the question it answers is what the graph costs when nothing in user code needs
it.

The structural claim to keep in view while reading §5: **P4's dispatch does exactly the same two
field comparisons P3's does** (`m.rows !== prev.rows`, `m.selected !== prev.selected`). Under TEA
the platform *cannot* know less than that, and it cannot know more, because `update` returns a whole
model. Fine-grained reactivity as a *programming model* — P5, the Solid app — is different in kind:
there `setLabel` on row 7 is a write to one signal and nothing walks 1 000 rows at all.

---
### 8.1 What it measures

`p4-signals` geometric mean **1.168** against the best, **1.141** against vanillajs, **1.828**
against vanillajs on script. Solid 2's are **1.168 / 1.141 / 1.767**.

**P4 and Solid 2 are the same number to three decimal places on the geometric mean, and within
noise on every individual operation** (the largest gap is `update 10th`, 2.78 against 2.35 ms of
script, and the smallest is `remove`, 0.57 against 0.83 in P4's favour). That is the expected
result and it is worth stating plainly: **the programming model on top of Solid's runtime does not
change what Solid's runtime costs.**

So P4 answers its question cleanly. Putting The Elm Architecture on a signal graph:

* **costs what the graph costs** — 1.828 against vanilla's 1.000 on script, against P2's 1.143 and
  P3's 0.989. The graph is 1.6–1.8× the templates-and-holes approach on this benchmark;
* **costs what the graph weighs** — 69 228 raw / 22 375 brotli bytes, against P3's 4 518 / 1 808
  (§12.1). That is **12×**;
* **buys nothing the compiler could not have given**, because the only thing `mapArray` does with
  the immutable model that P2 does not is the same `row !== lastRow` comparison, wrapped in a signal
  write and a scheduled effect;
* **and is the shape Solid's own team measured as the best way to feed a signal graph immutable
  snapshots** (R27 §7.8: 96/96 uibench cases, `createSignal(snapshot)` + keyed `<For>` beating
  store + `reconcile`). So this is not a badly-built P4. It is the good one.

### 8.2 What P4 does buy, and it is not speed

One thing, and it should be said because it is the honest case for the design: **the dependency
edges are discovered at run time, so they are always right.** P3's rung 3 is a static analysis, and
a static analysis has a precision bound; where it cannot prove which fields a hole reads it has to
fall back to P2's per-hole comparison. A signal graph never has that problem.

The measurement says that bound is worth 0.15 of a geometric mean (P2 1.143 against P3 0.989) and
the graph costs 0.68 (P4 1.828). **The fallback is cheaper than the graph by a factor of four**, and
it is also the thing R27 §0.5 already identified: *"(C) is not a different design from (B); it is
(B) with the compiler narrowing which holes to visit."*

---
## 9. Memory

Four points, the official benchmark's: after load, after 1 000 rows, after 10 000 rows, and after
five create/clear cycles. Two instruments, because they answer different questions:

* `performance.measureUserAgentSpecificMemory()` — what the official Playwright/Puppeteer runner
  uses. It counts the whole agent, DOM nodes included, and needs the page to be
  cross-origin-isolated, so `serve.mjs` sends `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`.
* CDP `HeapProfiler.collectGarbage` + `Runtime.getHeapUsage` — the JavaScript heap only, which is
  the number that isolates what the *strategy* retains from what the DOM costs.

`window.gc({type:'major',execution:'sync',flavor:'last-resort'})` is called before each sample, as
the official runner does; Chrome is launched with `--js-flags=--expose-gc`.

---
### 9.1 What it measures

Megabytes. `agent` is `performance.measureUserAgentSpecificMemory()` — the whole agent, DOM
included; `js` is CDP `Runtime.getHeapUsage` after `HeapProfiler.collectGarbage` — the JavaScript
heap only. Both after `window.gc({type:'major'})`. n = 1, as the official benchmark does.

| subject | ready | 1 000 rows | 10 000 rows | after 5× create/clear | **JS bytes retained per row** |
|---|--:|--:|--:|--:|--:|
| vanillajs-lite | 0.504 | 1.611 | 11.129 | 0.586 | **7** |
| vanillajs-3 | 0.491 | 1.653 | 11.566 | 0.544 | 74 |
| vanillajs | 0.507 | 1.789 | 12.771 | 0.564 | 186 |
| **p2-tpl** | 0.527 | 1.844 | 12.822 | 0.593 | **189** |
| **p3-fields** | 0.526 | 1.846 | 12.823 | 0.602 | **189** |
| **p2-tpl-cons** | 0.589 | 1.932 | 13.146 | 0.662 | **213** |
| **p3-fields-cons** | 0.588 | 1.933 | 13.152 | 0.670 | **214** |
| ivi | 0.578 | 2.183 | 15.715 | 0.690 | 487 |
| blockdom | 0.603 | 2.396 | 17.360 | 0.727 | 651 |
| **p1-vdom** | 0.513 | 2.455 | 18.624 | 0.655 | **790** |
| **p1-vdom-lazy** | 0.513 | 2.526 | 19.250 | 0.661 | **859** |
| solid 1.9 | 0.535 | 2.593 | 20.152 | 0.692 | 951 |
| inferno | 0.570 | 2.649 | 20.195 | 0.750 | 952 |
| svelte 5 | 0.610 | 2.784 | 20.506 | 0.898 | 980 |
| **p4-signals** | 0.729 | 2.926 | 20.195 | 1.190 | **936** |
| **Solid 2** | **0.727** | **2.964** | **20.590** | **1.193** | **977** |
| elm 0.19 | 0.735 | 3.618 | 27.774 | 1.085 | 1 727 |
| react-hooks 19 | 1.121 | 4.340 | 31.028 | 1.920 | 2 026 |

The last column is `(js bytes at 10 000 − js bytes ready) / 10 000` and it is the one that separates the
strategies, because the agent column is dominated by DOM nodes that every implementation allocates
identically.

**A compiled template retains 189 bytes of JavaScript heap per row. A signal graph retains 977.**
Five times. The 189 is one instance record (`{el, row, sel, idT, lbT}`), the row record itself, and a
`Map` entry; the 977 is R27 §10.6's list — *"the row object, its signal pair and node, the `<For>`
mapping entry, the per-row owner, the `class` effect node and handles to 8 DOM nodes"* — measured
there at ~1 380 bytes on a different app shape, and here at 951–977 on this one.

**The virtual DOM retains 790–859**, which is the vnode tree it must keep to diff against next time.
`lazy` adds 69 bytes per row for the thunk and its ref array.

**beni's `List` costs 24 bytes per row over the array** (213 against 189) — one cons cell, `{$, a,
b}`, which is exactly what a padded three-field object costs in V8. That is the *representation*
cost of the cons list, as distinct from the *algorithmic* cost §10 measures.

**Nothing leaks.** Every subject returns to within 0.2 MB of its ready figure after five
create/clear cycles; the prototypes to within 0.08.

---
## 10. The list, which is the other half of the question

§5–§8 measure renderers. This section measures the **model**, because under TEA half the cost of a
message is `update`, and `update` is the language's, not the renderer's.

### 10.1 What `core/` ships, and what it does not

`core/List` is a cons list and it is the only sequence in the language. There is no `Array`, no
persistent vector, no indexed read and no indexed write. `List.length` is a fold. `Dict` exists and
is a balanced tree ordered by the key type's `compare`, so a `Dict Int Row` gives O(log n) lookup
but no order, which a table needs. The `List` API is 40 functions and none of them is `get i`.

That is not an oversight; `backend.md` §4 parks it in writing — *"cons cells …, **pending M3c's
benchmark of a vector trie**"* — and says the benchmark is owed *"on real idiomatic code"*. This
section is that benchmark, on the most ordinary piece of idiomatic UI code there is.

### 10.2 The measurement

`proto/listmicro.js` imports `Bench$update` — the **real compiler's output**, not a hand transcription
— and times each message against the same model held as a JS array with a hand-written `update`
whose every line is what beni's emitter would produce for an indexable sequence. No DOM is involved;
this is `update` alone. Median of 20–60 repetitions after warm-up, at 1 000 and 10 000 rows.

---
### 10.3 What `update` costs, array against `List`

**Microseconds per call**, median of 15 samples each amortising 6–200 calls (because
`performance.now()` ticks at 5 µs even cross-origin-isolated). No DOM. The cons column is
`Bench$update` as the compiler emitted it; the array column is the same `update` written for an
indexable sequence.

| operation | **1 000 rows** array | **1 000** `List` | ratio | **10 000** array | **10 000** `List` | ratio |
|---|--:|--:|--:|--:|--:|--:|
| `Swap` (rows 1 ↔ 998) | **0.25** | **20.4** | **81×** | **3.3** | **212.5** | **64×** |
| `Append` 1 000 | 0.5 | 4.5 | 9× | 5.0 | 140.0 | 28× |
| `UpdateEvery10` | 1.9 | 36.4 | 19× | 51.7 | 165.0 | 3.2× |
| `Remove` by id | 9.6 | 12.9 | 1.3× | 140.0 | **97.5** | **0.7×** |
| `Select` | 0.07 | 0.05 | — | 0.05 | 0.02 | — |
| `Clear` | 0.05 | 0.05 | — | 0.02 | 0.02 | — |
| `Replace` | 170 | 150 | — | 1 192 | 1 042 | — |
| *walk to an array* (what a renderer needs) | 1.8 | 3.6 | 2.1× | 9.2 | 32.5 | 3.5× |
| `List.length` | — | 2.0 | — | — | 20.8 | — |

`Replace` is not a comparison of `update`: both figures are dominated by *constructing* the 1 000
or 10 000 row records, which is inside the timed call. It is in the table so the row is not missing.

Five things follow.

**1. `Swap` is the outlier, at 64–81×, and it is not an implementation defect.** §2.1 shows the
emitted code: `List.length` to check the guard (O(n)), two `drop`-then-`head` walks to reach
elements 1 and 998 (O(n)), then `indexedMap` over the whole list rebuilding every cell (O(n) time
and O(n) allocation). The array version is `slice` — one `memcpy` — plus two index writes. **There
is no way to write it better in beni**, because `List` has no indexed read; the source in Appendix A
is what a competent beni programmer writes and it is what the compiler faithfully compiled.

**2. `Append` degrades with size, 9× → 28×**, because `List.append xs ys` rebuilds all of `xs`,
while `Array.prototype.concat` on two packed arrays is a `memcpy`.

**3. `Remove` is *faster* on the cons list at 10 000 rows** — 97.5 µs against 140. beni's
`List.filter` is a compiled loop building cons cells; `Array.prototype.filter` calls a closure with
three arguments per element and grows its result. This is the one row where the cons list wins, and
it is worth recording because it shows the comparison is not rigged.

**4. `Select` and `Clear` are free in both**, at 20–70 nanoseconds. A record update of a two-field
record is what §2 said it was: one small object.

**5. In absolute terms, none of this makes the benchmark slower.** The worst cons-list `update` in
the table is 212 µs — **0.21 ms, 1.3 % of a 16.7 ms frame**, at ten thousand rows. That is why
§5.2's totals for `p2-tpl-cons` and `p3-fields-cons` sit beside their array twins rather than
behind them, and why `p3-fields-cons`'s geometric mean (1.056) is barely distinguishable from
`p3-fields`'s (1.054).

### 10.4 So what is the finding?

**`List` is not a speed problem at UI sizes. It is a capability gap, and the gap is `get`.**

* A beni program **cannot name element *i* of a sequence** in better than O(i). Every table view,
  every virtualised list, every "move this row up", every drag-and-drop reorder is written against
  that. The benchmark's `Swap` is the smallest possible instance of it and it costs 64–81×.
* `List.length` is O(n) — 20.8 µs at 10 000 rows — and it is called by ordinary guard conditions.
* **A renderer over a `List` must materialise an array to reconcile**, at 3.6–32.5 µs per render.
  Under P2, which re-runs top-down, that happens on *every* message including ones that do not touch
  `rows`; under P3 the field diff means it happens only when `rows` changed. That is rung 3 paying
  for itself for a second reason (§7.5).
* And the cons cell costs **24 bytes of retained JavaScript heap per row** over the array (§9.1).

`backend.md` §4 parked this in writing — *"cons cells …, pending M3c's benchmark of a vector trie"*
— and promised the benchmark would be *"on real idiomatic code"*. This is it, and the answer is
that the thing to measure next is not a trie against a cons list; it is **what an `Array` should be**:

> **A caveat that matters for F3.** The array column above is a *copy-on-write JavaScript array* —
> `slice`, index assignment, `concat`, `filter`. It is not a persistent vector. A 32-way trie would
> make `Swap` O(log₃₂ n) instead of O(n), which at 10 000 rows is about 3 node copies instead of
> 10 000 — but each of those copies is a 32-element array allocation, and the constant is large
> enough that for `Append`, `Remove` and the full-list walk a plain copy-on-write array beats it.
> **Nobody has measured which shape beni should ship**, and this report does not. What it establishes
> is that the current answer — no indexable sequence at all — is the one that cannot be right.

---
## 11. Beyond the table: four experiments the krausest benchmark cannot see

The table benchmark flatters keyed-list machinery. Nearly every operation it times is dominated by
creating, moving or destroying 1 000 `<tr>`s, and every framework in the top twenty has the same
keyed reconciler underneath. It says very little about an ordinary UI — a page that is mostly static
markup with a few dynamic holes, a component tree with a prop threaded through it, or an animation
that writes one value per frame.

Four experiments, all in `proto/micro.js` + `proto/micro-main.js`, plus the signals column from
`p5micro/src/main.jsx`. **These are in-page `performance.now()` measurements with a forced layout
read (`document.body.offsetHeight`) after each iteration, so style and layout are inside the window
and paint is not.** That is a different instrument from §5's trace-based click-to-paint and the two
must not be mixed; it is the right instrument here because what is being compared is the *script*
cost of a strategy at a hole count the table never reaches.

| # | Experiment | Shape |
|---|---|---|
| E1 | a wide static-heavy page | 2 000 elements, 50 dynamic text holes, **one** hole changes per message |
| E2 | a deep component tree | depth 50, one leaf value changes |
| E3 | high-frequency updates | K ∈ {1 000, 10 000} holes written per animation frame for 120 frames, and the same frequency through a full vdom rebuild of 1 000 and 5 000 cells |
| E4 | building 1 000 rows cold | `cloneNode` vs `createElement` chains vs `innerHTML` vs the vdom's create path, detached and attached |

E1 is the one that matters most, and the reason is asymptotic: the table benchmark's list hole is
*the whole app*, so a vdom's O(everything) and a template's O(holes) coincide. On a real page they do
not — a page can have 2 000 elements and 50 holes, and then a vdom pays for the 1 950 elements
nobody is looking at while a template pays nothing for them at all.

---
### 11.1 E1 — a wide, static-heavy page

2 000 elements, 50 of them dynamic text holes, one hole changed per message. **Microseconds of
script per message** (no layout, no paint), and beside it the same message with a forced layout,
which is what the browser charges.

| strategy | script µs, 1× | script µs, 4× | +forced layout, ms, 1× | 4× |
|---|--:|--:|--:|--:|
| **P1 — virtual DOM** | **327.5** | **1 130.5** | 0.78 | 2.74 |
| **P1 + `lazy`** | **80.5** | **242.5** | 0.54 | 1.85 |
| **P2 — templates, 50 hole checks** | **2.25** | **2.0** | 0.48 | 1.75 |
| **P3 — field-directed** | **3.5** | **3.5** | 0.48 | 1.78 |
| **Solid 2 signals** (`p5micro`) | **1.75** | **6.08** | 0.48 | 1.67 |
| floor — one `nodeValue` write | 0.175 | 0.15 | 0.47 | 1.69 |
| `update` alone — a 50-field record update | 0.20 | 0.175 | — | — |

**This is the experiment the table benchmark cannot run, and it is the most one-sided result in the
report.** A virtual DOM costs **146× a compiled template** per message at 1× and **565× at 4×**,
because it rebuilds a description of 2 000 elements to discover that 1 999 of them did not change.
`lazy` brings it to 36×, and only if every one of the 2 000 cells carries a thunk. A template
prototype costs 2.25 µs — **0.013 % of a 16.7 ms frame** — and Solid's signal graph costs 1.75 µs.

**And a result that corrects an assumption in §0.3: on this page P3 is not faster than P2, it is
marginally slower** — 3.5 µs against 2.25. The reason is structural and worth stating, because it
bounds what rung 3 is for: this model has **50 fields and 50 holes in one-to-one correspondence**, so
a field-level diff *is* fifty comparisons, exactly what P2's per-hole check already was, plus the
bookkeeping to dispatch on the result. **The field diff pays where one field feeds many holes** —
`selected` feeding 1 000 rows, which is §7.4 — and not where each hole has a field to itself.

The last two rows are the floor and they say something about the whole exercise: **a 50-field record
update costs 0.2 µs and writing the one text node costs 0.175 µs**, so P2's entire overhead over
doing the minimum possible is **1.9 µs per message**. At 60 messages a second that is 0.011 % of the
CPU.

With a forced layout in the window, every strategy except the unthunked virtual DOM is
indistinguishable — 0.47–0.54 ms, of which 0.47 is Chrome restyling 2 000 cells.

### 11.2 E2 — a deep component tree, one leaf changes

Depth 50, one value threaded to the leaf. Microseconds of script per message.

| strategy | 1× | 4× |
|---|--:|--:|
| P1 — virtual DOM | 7.9 | 14.9 |
| Solid 2 signals | 1.18 | 4.58 |
| **P2 / P3 — template** | **0.125** | **0.125** |

**A compiled template does not know the tree is deep.** After construction the hole is a text node
reference and the write is a `nodeValue` assignment; depth 50 costs the same as depth 1. The virtual
DOM walks 50 levels every message (**63×**); the signal graph pays one write plus one effect
(**9.4×**). Both are still microseconds, and with a forced layout all three are 0.06–0.07 ms.

### 11.3 E3 — high-frequency updates, 120 animation frames

Frames whose delta exceeded 20 ms are "late". Median frame delta in milliseconds.

| workload | 1×: median Δ / late | 4×: median Δ / late |
|---|---|---|
| 1 000 text holes written per frame | 16.66 / **0** | 16.66 / 4 |
| 10 000 text holes per frame | 49.99 / **119** | 150.0 / 119 |
| vdom rebuild of 1 000 cells per frame | 16.67 / **0** | 16.67 / **1** |
| vdom rebuild of 5 000 cells per frame | 16.67 / 22 | 83.33 / 118 |

**At 1 000 holes nothing drops a frame, even through a full virtual-DOM rebuild, even at 4× CPU
throttling.** The knee is between 1 000 and 5 000 for the vdom and between 1 000 and 10 000 for
direct writes, and at 10 000 direct writes the cost is *layout*, not script — 50 ms per frame is
Chrome restyling ten thousand cells, which no architecture avoids.

So the honest reading of E3 is: **for an animation driving up to about a thousand holes a frame,
every strategy here holds 60 Hz and the question does not arise.** Past that, the ordering is the
one E1 gives.

### 11.4 E4 — building 1 000 rows, four ways

Microseconds to build 1 000 rows into a **detached** `<tbody>` — no insertion, no layout, so this is
construction cost alone.

| construction | µs, 1× | µs, 4× | per row, 1× |
|---|--:|--:|--:|
| **`cloneNode` from a `<template>`** | **2 653** | **9 225** | **2.65 µs** |
| `createElement` chains | 3 822 | 13 707 | 3.82 µs |
| `innerHTML` of the whole body | 4 620 | 16 932 | 4.62 µs |
| the P1 vdom's `create` path | 4 658 | 17 432 | 4.66 µs |

**Template cloning is 1.44× cheaper than `createElement` chains and 1.76× cheaper than the virtual
DOM's create path.** That is the other half of what a compiler that sees the markup buys, and it is
the half that shows up on `create 1k` and `create 10k` in §5.4 (p2-tpl 2.45/30.06 ms against
p1-vdom's 3.98/54.89).

`innerHTML` is the slowest, which is worth recording because it is the intuition people have about
it: parsing 1 000 rows of HTML text costs more than cloning a prepared subtree 1 000 times.

Attached, with a forced layout, the same four are 25.06 / 26.33 / 27.54 / 26.43 ms — the 2 ms of
construction difference inside 23 ms of Chrome laying out a 1 000-row table. Which is §5.5 again.

---
## 12. Size and startup

**Size** is every `.js`/`.mjs` file the page loads, excluding the shared `currentStyle.css` and any
`LICENSE.txt`, concatenated and then compressed — raw, gzip −9, and brotli quality 11. Concatenating
before compressing is what a bundle does and is what R26 §8.3 measured as worth −15.4 % brotli over
per-file compression; the prototypes that load beni's compiled `core` load **nine** files, so the
concatenated figure is the fair one for all subjects.

Three caveats, all of which move numbers:

1. **The prototypes are not minified.** They are the hand-written source with its comments, served
   as one ES module. Their raw column is therefore meaningless as a shipping figure and their brotli
   column is roughly right (comments compress well, but not to nothing). Where a size claim matters
   below, the comment-stripped figure is given beside it.
2. **beni's compiled `core` is not minified either**, and R26 §8.3 already found that sibling `.js`
   is 71.6 % of a small program's bytes and *"the first stage in the pipeline that touches the
   sibling JavaScript at all"* is bundling. The `-cons` prototypes carry that cost in full.
3. **Elm is `--optimize` without the uglify pass** (§1.6), so its raw figure is about 4× what the
   published table reports.

**Startup** is measured three ways per subject, fresh page and disabled cache each time: the page's
own `first-contentful-paint`, the sum of resource durations for its scripts, and the wall time from
clicking `#run` to 1 000 rows being laid out. This is a localhost HTTP/1.1 measurement with no
network emulation; **R26 §8.2 is the network-limited version of the same question** and its
conclusion — one bundle loads 3.0× faster to `main` on 4G — is not re-derived here.

---
### 12.1 Size

Every `.js`/`.mjs` the page loads, concatenated, then compressed. `as served` is what each subject
actually ships; `minified` is the same source through `terser --compress --mangle --module`, which
the framework builds already had and the prototypes did not.

| subject | files | as served, raw | gzip −9 | **brotli 11** | minified raw | **minified brotli** |
|---|--:|--:|--:|--:|--:|--:|
| vanillajs-lite | 1 | 2 308 | 1 123 | **992** | — | — |
| vanillajs-3 | 1 | 2 958 | 1 177 | **1 016** | — | — |
| vanillajs | 1 | 9 486 | 2 521 | **2 172** | — | — |
| **p2-tpl** | 1 | 13 555 | 5 082 | 4 368 | **4 143** | **1 682** |
| **p1-vdom** / **p1-vdom-lazy** | 1 | 10 761 | 4 284 | 3 719 | **4 440** | **1 787** |
| **p3-nosel** | 1 | 13 562 | 5 081 | 4 373 | **4 518** | **1 806** |
| **p3-fields** | 1 | 13 561 | 5 081 | 4 374 | **4 518** | **1 808** |
| ivi | 1 | 9 619 | 4 346 | **3 878** | — | — |
| solid 1.9 | 1 | 11 563 | 4 810 | **4 358** | — | — |
| blockdom | 1 | 17 099 | 5 697 | **5 152** | — | — |
| **p2-tpl-cons** | 9 | 35 732 | 12 070 | 10 592 | **10 833** | **3 758** |
| **p3-fields-cons** | 9 | 35 738 | 12 072 | 10 600 | **11 208** | **3 872** |
| inferno | 3 | 29 612 | 10 398 | **9 469** | — | — |
| svelte 5 | 2 | 27 081 | 10 745 | **9 809** | — | — |
| **Solid 2.0.0-rc.9** | 1 | **68 531** | **24 413** | **22 163** | — | — |
| **p4-signals** | 1 | 69 228 | 24 671 | **22 375** | — | — |
| elm 0.19 `--optimize` | 1 | 128 577 | 29 481 | **25 523** | — | — |
| react-hooks 19 | 1 | 194 643 | 61 132 | **52 423** | — | — |

**Solid 2 is 5.1× Solid 1.9's compressed size** — 22 163 against 4 358 brotli, for the same app.
R27 §10.3 has the reason from the source side: `@solidjs/signals` is ~75 % of the bundle in an
empty app, and *"`scheduler.js` + `async.js` + `heap.js` + `lanes.js` — about 14 KB minified of
scheduling and async machinery"* is in the floor of a program that does nothing asynchronous. This
benchmark app does nothing asynchronous.

**The template prototypes are the smallest renderers measured that are not hand-written vanilla
JavaScript**: 1 682–1 808 bytes brotli minified, against ivi's 3 878 and Solid 1.9's 4 358. And they
are *not comparable as shipped artefacts* — see the caveat below.

**beni's compiled `core` costs about 2 kB brotli here.** `p2-tpl-cons` 3 758 against `p2-tpl`'s
1 682: the difference is `List.mjs`, `Basics.mjs`, `String.mjs` and their three `.foreign.mjs`
siblings, minified, which is 17 290 bytes raw before minification. R26 §8.3's finding that sibling
`.js` is never minified and is 71.6 % of a small program's bytes is visible here as the gap between
the `as served` column (10 592) and the `minified` column (3 758) — **a 2.8× difference on a
9-file tree, from minification alone.**

**The caveat, and it is large.** The prototypes are not shipping renderers. They contain no element
or attribute vocabulary, no event system beyond one delegated `click` listener, no XSS sanitisation
(R24 §6.3 measures Elm's at ~60 lines and says *"there is no cheaper way to get it"*), no
`requestAnimationFrame` batching, no subscriptions, no scheduler and no fiber runtime. A real beni
browser platform is all of that plus these. **The right reading of the size column is the
*difference* between strategies, not the absolute figure**: a template renderer is ~1.7 kB brotli
of machinery and a signal graph is ~22 kB, and whatever else the platform adds, it adds to both.
R24 §11.4's estimate of a beni counter at 35–50 kB raw was made on the assumption of a virtual DOM
and remains the only estimate; W11 asks for the real number and this report does not supply it.

---
### 12.2 Startup

Fresh page and disabled cache per sample, n = 8, medians, localhost HTTP/1.1, unthrottled.
`fcp` is the page's own first-contentful-paint; `resource` is the summed duration of its script
resources; `to 1k rows` is the wall time from clicking `#run` to 1 000 rows laid out.

| subject | fcp (ms) | resource (ms) | click → 1k rows (ms) |
|---|--:|--:|--:|
| p1-vdom | 28.6 | 2.4 | 60.0 |
| vanillajs-lite | 29.3 | 2.5 | 50.0 |
| p3-fields | 29.3 | 2.5 | 50.5 |
| solid 1.9 | 29.3 | 2.4 | 59.5 |
| ivi | 29.5 | 2.4 | 51.0 |
| **p2-tpl** | **29.6** | **2.4** | **50.0** |
| p1-vdom-lazy | 29.8 | 2.4 | 59.0 |
| inferno | 29.8 | 2.4 | 60.0 |
| **p3-fields-cons** | 29.8 | **19.7** | 52.0 |
| **p2-tpl-cons** | 30.0 | **19.8** | 51.0 |
| blockdom | 30.0 | 2.4 | 57.5 |
| p3-nosel | 30.0 | 2.3 | 51.5 |
| vanillajs | 30.7 | 2.5 | 50.5 |
| vanillajs-3 | 31.0 | 2.4 | 51.0 |
| svelte 5 | 31.9 | 2.6 | 58.5 |
| p4-signals | 32.1 | 2.4 | 63.5 |
| elm 0.19 | 33.3 | 2.4 | 69.5 |
| **Solid 2** | **33.9** | **2.5** | **63.0** |
| react-hooks 19 | 56.0 | 2.5 | 72.0 |

Three things worth taking from it.

**First paint is flat at 29–34 ms for everything except React**, because on localhost the bytes
arrive instantly and what is left is parse plus first render. Solid 2's 33.9 against Solid 1.9's
29.3 is 68 kB of bundle being parsed instead of 11.

**The nine-file prototypes pay 19.8 ms of resource time against 2.4** — beni's module graph over
HTTP/1.1 — and it does not reach their first paint, because the files are tiny and localhost has no
round trip worth the name. R26 §8.2 is the measurement that matters and is not re-derived here: over
4G the same shape of graph took **1 059 ms to `main` against a single bundle's 358**, a 3.0×
difference *"from round-trip depth rather than bytes"*. A browser platform ships one file; this is
more evidence for W13, not a new argument.

**Click to 1 000 rows sorts the strategies the way §5 does**: 50–52 ms for vanilla and the template
prototypes, 57–64 for the virtual DOM and the two signal libraries, 69.5 for Elm, 72 for React.

---

## 13. Questions for the owner

Same shape as the effects, browser and Solid sheets: the situation in plain words, a small example,
the options, a recommendation. Ids are `F1…F8`, so they collide with nothing — `W1…W24` is the
browser sheet, `S1…S7` is report 27, `J1…J5` is report 28. **Nothing here is decided.**

### F1. Does `view` return a tree the platform compares, or a template the compiler fills in?

**The situation.** `plans/browser-decisions.md` W1 came with a rider — *"`view` returns a data tree
the platform renders — a virtual DOM"* — written before anybody measured. The programmer sees the
same thing either way: a function from the model to markup. What differs is what the compiler emits.
A virtual DOM builds a fresh description of the whole screen on every message and compares it with
the previous one. A compiled template builds the unchanging markup once, and only ever revisits the
places where a value can appear.

**The example.** A table of 1 000 rows; you click one row to highlight it. The virtual DOM builds
9 000 small objects describing every cell of every row, compares them all, finds two that differ and
writes two `class` attributes: **5.64 ms of script**. With Elm's `lazy` written in the form that
works, it builds 1 000 thunks instead and compares their arguments: **2.31 ms**. The template
version compares 1 000 row records against last frame's and writes the same two attributes:
**1.71 ms**; told by the compiler that only `selected` changed, **0.49 ms**. Solid 2 does it in
**2.60 ms**, Solid 1.9 in 1.38.

**The options.** (a) a virtual DOM; (b) compiled templates re-run top-down with one reference
comparison per hole — report 27's strategy B, this report's P2; (c) (b) plus compile-time knowledge
of which model fields feed which hole — strategy C, P3.

**What each costs.** (a) is the least compiler work and the most run-time work, and on the one
operation that separates the strategies it is the slowest thing measured that is not React. It is
also the option that *needs* `lazy` to be competitive, which drags W4 and a reference-identity
guarantee in `language.md` along with it (F4, F6). (b) needs the compiler to split static markup
from dynamic holes — which report 28 §8.1 says it should do anyway, over ordinary `Html.div` calls,
whether or not JSX ships — plus the language property that `===` on an immutable value means "deeply
unchanged", which beni has. (c) adds one analysis.

**Recommendation: (c), built as (b) first.** Not (a). The evidence: **P2 already beats Solid 2 on
every one of the nine operations** and beats Solid 1.9 on seven; **P3 lands at a geometric mean of
0.989 against hand-written keyed vanilla JavaScript's 1.000**, while the programmer writes one
immutable model and a pure `update`; and (b)→(c) is additive with no user-visible change, which is
what R27 §0.5 already said and this report confirms. Building (b) first is not a staging
convenience — §7.4 measures that **four fifths of P3's advantage comes from the field diff (rung 3)
and one fifth from the selector recognition (rung 4)**, so even a partial analysis pays.

**Rule 7 check.** Nothing is refused. A template renderer withholds nothing a virtual DOM offers:
the programmer still writes `view : Model -> Html Msg` and still gets a data tree in the source; the
*compiler* stops materialising it. If the recogniser cannot prove a piece of markup is literal, it
must fall back to building and diffing nodes for that subtree — which is (a), retained as the
fallback rather than as the architecture.

**Reversibility: medium.** It is a `backend.md` pass and a platform contract, not a type in every
program. (a) → (b) later is possible; but a program written against a `lazy`-bearing virtual DOM
carries `lazy` annotations that a template renderer has no use for, so (a) is not free to leave.

### F2. If templates, when does the compiler learn which fields feed which hole?

**The situation.** P3 is P2 with the compiler narrowing which holes to visit. It is strictly an
optimisation of P2, never a different program, and where the analysis cannot prove what a hole
reads it degrades to P2's comparison for that hole.

**The example.** `class={if row.id == model.selected then "danger" else ""}`. Rung 3 is knowing the
hole reads `model.selected`; rung 4 is recognising the whole expression as an equality-keyed
selector so the runtime can keep a key→row index and touch two rows instead of a thousand.

**The options.** (a) build P2 now, leave the analysis for later; (b) build both together;
(c) build P2 and never build the analysis.

**Recommendation: (a).** P2 is already ahead of Solid 2 everywhere and ahead of Solid 1.9 almost
everywhere; the analysis is worth 0.154 of a geometric mean on this benchmark (1.143 → 0.989) and
more on an ordinary page (§11). Nothing is lost by sequencing it second, and `backend.md`'s new
section can be written so the hole table has a place for the dependency set from the start.

**Reversibility: high.** Fully internal.

### F3. Does `core/` get an indexable sequence?

**The situation.** `core/List` is a cons list and it is the only sequence beni has. There is no
indexed read, no indexed write, no `Array`, no persistent vector. `List.length` is a fold. `Dict`
is a balanced tree, so it gives O(log n) lookup and no order.

**The example.** "Swap rows 1 and 998" in a 1 000-row table. There is no way to write it in beni
except to walk to element 1, walk to element 998, and rebuild the whole list with `indexedMap` —
which is what the compiled `update` in §2.1 does, because it is what the source says.

**The options.** (a) ship a persistent vector as `core/Array`, with `get`, `set`, `push`, `slice`
and a `List` interconversion; (b) say cons lists are enough and write down why; (c) add indexed
operations to `List` that are O(n) and document the cost.

**Recommendation: (a), and it is rule 7's exact shape.** Not because this benchmark demands it —
§10 measures the `List` version of `update` as a fraction of a millisecond at 1 000 rows, which is
nothing against a 28 ms operation — but because **an ordinary developer cannot write `Array`
themselves.** Rule 6 means only `core/` and platforms may write `foreign`; `backend.md` §4 has
parked a vector trie *"pending M3c's benchmark"* since M3 began and §10 is that benchmark; and
CLAUDE.md rule 7 says in as many words that *"whatever `core/` and the platforms do not ship, the
language is withholding"*. A table view is the most ordinary UI there is, and beni cannot express
"swap two rows" in better than O(n). That is a capability gap, not a taste question.

The honest counter-argument, and it should be recorded: a **persistent** vector (a 32-way trie) is
not free either — it is O(log₃₂ n) with a large constant, it is several hundred lines inside the
wall, and for a 10 000-row model a *copy-on-write JavaScript array* (`slice`, `with`, `toSpliced`)
is faster than both a trie and a cons list for every operation this benchmark performs. So (a)'s
real question is *which* array, and that is a second measurement nobody has taken.

**Reversibility: high.** Adding a module to `core/` is additive.

### F4. Does `language.md` promise that an untouched field keeps its identity?

**The situation.** beni emits `{ m | f = x }` as a JavaScript spread (§2, fact 2), so every field
except `f` comes out of the new record pointing at exactly the value it pointed at before. Every
strategy in this report except the virtual-DOM-without-`lazy` depends on that: `row === inst.row`
is the whole of P2, and it is only meaningful because an unchanged row is the *same object*.

R24 §6.8 established that this **holds today by construction and is nowhere promised**, and that
Elm never wrote it down either.

**The options.** (a) write the guarantee into `language.md` §6 — an update preserves the identity of
every field it does not name, and no optimiser pass may break it; (b) leave it unwritten and depend
on it anyway; (c) leave it unwritten and do not depend on it, which means the virtual DOM without
`lazy` and nothing faster.

**Recommendation: (a).** It is cheap now and expensive later. The cost is a sentence that constrains
future optimiser passes — and the passes it constrains are ones nobody wants: a pass that
*re-materialised* an unchanged field would be adding an allocation. It is not the same commitment
W4 worried about, because W4's was about licensing `lazy` to **skip a call**, which needs purity;
this one only says a record update does not deep-copy.

**Reversibility: low once written**, which is the point of writing it.

### F5. What is the budget for "working out what changed"?

**The situation.** R27 §11 S3 asks for a published number and suggests 1 ms. This report has the
measurement to set one against.

**The evidence.** At 1 000 rows, under 4× CPU throttling, the model-to-screen step costs 0.03 ms
(P3), 0.27 ms (P3 without the selector) or 1.30 ms (P2) — against a frame of 16.7 ms and a paint of
3 ms. Unthrottled, divide by roughly four.

**Recommendation: publish 1 ms at 60 Hz, measured as the time from "`update` returned" to "the DOM
is consistent with the model", excluding layout and paint.** Every strategy in this report except
the plain virtual DOM meets it at 1 000 rows with an order of magnitude to spare; the virtual DOM
meets it only with `lazy`. A published number is what lets a later change be called a regression.

**Reversibility: high.** It is a documented budget, not a mechanism.

### F6. Does `lazy` come back?

**The situation.** W4 recommended parking `Html.lazy` — *"(b) for now, which is C9 unchanged"* — on
the ground that nothing measured a need. This report measures one: **`lazy` is worth 2.336 → 1.323
on the geometric mean of script**, the single largest improvement any change here produced, and a
virtual DOM without it is the slowest architecture measured on `select`.

**But the finding cuts the other way.** `lazy` matters *because* a virtual DOM rebuilds everything.
Under P2 or P3 there is nothing for it to do: the template is already built, the holes are already
located, and the per-hole reference check is the memoisation. **If F1 answers (b) or (c), `lazy` has
no job.**

**The options.** (a) ship `lazy` (which requires W4's two demands in argument position); (b) keep it
parked; (c) ship templates and state in writing that `lazy` is subsumed.

**Recommendation: (c) if F1 is (b)/(c); (a) if F1 is (a).** They are not independent questions and
should be answered together. Note the asymmetry: choosing the virtual DOM commits to `lazy`, which
commits to the second argument-position demand *and* to F4's guarantee; choosing templates commits
to F4's guarantee only.

**Reversibility: (b) → (a) is additive; (c) is a statement, not a mechanism.**

### F7. Is the equality-keyed selector a compiler pattern, a platform function, or neither?

**The situation.** Rung 4 — making `Select` O(1) instead of O(rows) — needs something to recognise
that a hole's value is `some_expression == model.field` and that the enclosing list is keyed. Solid
has exactly this and makes the programmer write it: `createSelector` in 1.9, `createProjection` in
2.0, and Solid 2's own documentation gives the pattern under the heading *"Selection without
notifying every row"*.

**The options.** (a) the compiler recognises `x == model.f` inside a keyed list hole and emits the
index; (b) the platform exports a function the programmer calls, as Solid does; (c) neither — every
row is compared, which is `p3-nosel`.

**Recommendation: (c) first, then (a) if a real application asks.** The measurement is why:
`p3-nosel` is 1.051 against vanillajs and `p3-fields` is 0.989, a difference of 0.062 on the
geometric mean and 0.24 ms on the one operation it touches. **(b) is the option to refuse**, and
rule 7 is the reason: it is a performance annotation the programmer has to know to write, whose
absence is silent, and whose presence is a second way to say something the compiler can already see.
Solid needs it because Solid has no model to diff; beni would be importing a workaround for a
problem it does not have.

**Reversibility: high.** (c) → (a) changes no program.

### F8. Is there anything left that argues for signals as beni's *programming model*?

**The situation.** R25 ranked signals fourth of five and parked them on a soundness hazard (its
§7.3, the suspension point). R27 §8.6 then found the hazard does not survive `sync`. So the question
is open on its merits again, and this report is the performance half of the answer.

**The evidence.** Putting The Elm Architecture on Solid 2's runtime (P4) produces **the same
numbers as Solid 2** — geometric mean 1.168 against 1.168 — and costs **22 375 brotli bytes against
1 808**. Signals as the programming model (Solid itself) is **1.767 against vanillajs on script**
where compiled templates are **0.989**. On this benchmark, in this browser, signals are not the
fast option; they are the option that pays a graph to discover at run time what a compiler can
discover at compile time.

**What signals still have that the compiler does not:** run-time dependency discovery is exact,
where a static analysis has a precision bound and must fall back (F2). §8.2 prices that fallback at
a quarter of what the graph costs.

**Recommendation: no — and say so in writing**, so the question does not reopen each time someone
reads a Solid benchmark. The four guarantees R27 §9.1 lists as lost under signals (single source of
truth, exhaustive messages, time travel, state serialisation) are not being traded for speed,
because there is no speed to trade for. Keep R25 D10's position: not forbidden, not shipped, and
the kernel not deliberately closed against it.

**Reversibility: high** for a statement; low for the kernel decisions W19 and A7 already took.


---

## 14. Could not determine

**Leptos.** A Rust + `wasm-bindgen` toolchain was outside the 30-minute budget the brief set, so
there is no wasm column. The official table has it at a geometric mean of **1.250** against
vanillajs — slower than Solid 1.9's 1.110 — with **189.6 kB uncompressed / 48.8 kB compressed** of
payload, a 231.2 ms first paint, and the worst memory of any subject in that table (**1.76 MB**
ready, **5.42 MB** at 1 000 rows, against vanillajs's 0.57 and 1.86). A wasm column would not have
changed this report's conclusion in either direction.

**Million / blockdom's block-vdom family beyond blockdom itself.** `million` has no keyed entry
in this revision of the benchmark repo. `blockdom` is in, and is the block-vdom data point.

**Elm with its official uglify pass.** The framework's `build-prod` runs
`uglifyjs --compress 'pure_funcs=F2..A9,pure_getters,keep_fargs=false,unsafe_comps,unsafe,passes=2'`
then `--mangle`. Only `elm make --optimize` was run here, so Elm's **size** column is its raw
output and its **speed** column assumes the `pure_funcs` pass does not change run time materially.
That assumption is not measured. Elm's speed here is close to the published table's relative
position, which is weak evidence that it is right.

**Firefox and Safari.** One engine. R26 §1.6 says the same thing and for the same reason.

**A GPU-composited desktop Chrome.** Every paint figure is software-rasterised headless and is
roughly 2× the published one (§1.5). The *ranking* is unaffected (§5.2) and the *script* column is
not inflated, but no absolute total here should be quoted as a desktop number.

**Whether a real beni emitter reaches the prototypes' numbers.** The prototypes are hand-written.
They presume only analyses §3 names, and none of them special-cases an operation, but an emitter is
a different thing from a hand-written module and the gap is unmeasured. §13 F2 is where that
uncertainty lives.

**The cost of the field-dependency analysis in the compiler.** §7.2 measures what P3 buys at run
time. What it costs at *compile* time — a per-hole free-variable analysis over the view body, and
the pattern match for rung 4 — is not measured, because there is no implementation. beni's budget is
>250k LOC/s per core (`fast-compiler.md` §2) and this is a walk over one function body, so the
expectation is that it is noise; but that is an expectation.


**Two measurement floors were hit and fixed, and the first versions are wrong.** (1) `performance.now()`
ticks at 5 µs even cross-origin-isolated, so the first run of §10 and §11 reported zeros for every
operation faster than that; both were re-run with each sample amortising 6–200 calls, and only the
amortised numbers are published. (2) **Solid 2 flushes on a microtask** (R27 §3.1), so the first
version of the signals column in §11 measured `setSignal` returning and nothing else, at 0.005 ms;
it was re-run with `flush()` inside the timed window. The same artefact is still visible and
labelled in §5.6, where `p4-signals`'s in-page `render` column reads 0.01 ms for work that the
trace-based script column prices at 2.8 ms — **that row is an artefact, not a result**.

**The unthrottled pass is not a second opinion on the ranking.** §5.7: at 1× these three operations
take 2–18 ms with a standard deviation of 2–5 ms, so the `total` ordering is frame-boundary noise.
Only its script column is used.

**Three things the prototypes do not have to do, which a real renderer does**: build an element and
attribute vocabulary from a platform's declarations, sanitise what a `view` can inject (R24 §6.3
measures Elm's at ~60 lines and says there is no cheaper way), and batch renders onto an animation
frame. All three cost script that nothing here measures.

**Anything about hydration, server rendering, or a router.** Out of scope.

---

## 15. Evidence index

Everything below is in the scratchpad at
`…/scratchpad/bench-r3/`. Nothing was copied into the repository; this report is the only file the
work produced there.

### Harness

| File | What it is |
|---|---|
| `lib/cdp.mjs` | the CDP client — launch with the benchmark's flags, a page target per iteration, `Input.dispatchMouseEvent` clicks, a `readyState === "complete"` readiness gate. Derived from R26's `browser-r3/harness.mjs` |
| `lib/serve.mjs` | the static server, with COOP/COEP so `measureUserAgentSpecificMemory` works |
| `lib/trace.mjs` | the port of `webdriver-ts/src/timeline.ts` — `computeResultsCPU`, `computeResultsJS`, `computeResultsPaint`, plus median/sd |
| `lib/benchmarks.mjs` | the port of `benchmarksWebdriverCDP.ts` — the nine benchmarks, their warm-ups and their post-conditions, and `benchmarksCommon.ts`'s throttling factors |
| `bench.mjs` | the driver: rotation, tracing, throttling, the in-page `update`/`render` split |
| `verify.mjs` | drives all nine buttons on every subject and asserts the DOM |
| `report.mjs` | turns the JSON into the tables in §5 |
| `build-proto.mjs` | assembles the seven non-signal prototype pages |
| `micro.mjs`, `p5micro.mjs`, `listmicro.mjs`, `mem.mjs`, `startup.mjs`, `sizes.mjs` | §9–§12 |
| `runrest.sh`, `runrest2.sh`, `waiter2.sh` | the chains that run everything after the CPU batch, one at a time so nothing contends; `runrest2` is the re-run of §10 and §11 after their measurement floors were fixed |
| `dbg.mjs` | a one-page debug driver |

### Prototypes and apps

| File | What it is |
|---|---|
| `proto/common.js` | the TEA model, both representations, the dispatch wiring, the delegated table listener |
| `proto/p1-vdom.js` | P1 and P1L — the keyed diff, `lazy`, the view |
| `proto/p2-template.js` | P2 and P3 — the template, the holes, `reconcileArrays`, the field-directed render |
| `proto/micro.js`, `proto/micro-main.js` | E1–E4 |
| `proto/listmicro.js` | §10's `update`-only measurement, over the real compiler's `Bench$update` |
| `beniapp/Bench.beni` | **the model in beni**, 103 lines |
| `beniapp/out/` | what `beni build Bench.beni --library --platform=node` produced |
| `solid2/src/main.jsx` | the Solid 2 port of the benchmark app |
| `p4/src/main.jsx` | P4 — TEA over Solid 2's runtime |
| `p5micro/src/main.jsx` | E1/E2 with signals as the programming model |

### Outputs

| File | What it holds |
|---|---|
| `out/verify.txt` | the correctness pass, 19 subjects |
| `out/cpu-throttled.json`, `.log` | §5's main table — 9 benchmarks × 19 subjects × 10, official throttling |
| `out/cpu-unthrottled.json`, `.log` | `update 10th`, `select` and `swap` at 1× (§5.7) |
| `out/list.json` | §10 |
| `out/micro.json`, `out/p5micro.json` | §11, at 1× and 4× |
| `out/mem.json` | §9 |
| `out/startup.json` | §12 |
| `out/sizes.log`, `out/min/` | §12.1, as served and minified with `terser --compress --mangle --module` |
| `out/table-throttled.md`, `out/table-unthrottled.md` | the rendered tables §5 quotes |
| `out/official.md` | the published Chrome-152 table, extracted from `jfb/webdriver-ts/results.json`, for §5.2's check |

### How to re-run the two that matter

```sh
cd …/scratchpad/bench-r3
# 1. the main table (about 40 minutes)
node bench.mjs --subjects=vanillajs,solid,solid2,elm,p1-vdom,p1-vdom-lazy,p2-tpl,p3-fields,p4-signals \
               --n=10 --out=out/cpu.json
node report.mjs out/cpu.json

# 2. what beni's List costs `update` (about 30 seconds)
node listmicro.mjs
```

Both rebuild nothing. To rebuild the prototypes after editing `proto/*`: `node build-proto.mjs`. To
rebuild the beni model: `cd beniapp && …/zig-out/bin/beni build Bench.beni --library --platform=node`.

---

## Appendix A. `beniapp/Bench.beni` — the parts §2.1 does not show

§2.1 has the emitted `update`. This is the beni source of the two pieces that explain it: the model,
and the walk that exists only because `List` has no indexed read.

```elm
pub type alias Row =
    { id : Int, label : String }


pub type alias Model =
    { rows : List Row, selected : Int }


pub type Msg
    = Replace (List Row)
    | Append (List Row)
    | UpdateEvery10
    | Clear
    | Swap
    | Select Int
    | Remove Int


--| `List` has no indexed read, so this is the only way to name row 1 and
--| row 998: walk to them.
at : List Row, Int -> Row
at rows i =
    case rows |> List.drop i |> List.head of
        Just r ->
            r

        Nothing ->
            { id = 0, label =  }


pub update : Msg, Model -> Model
update msg model =
    case msg of
        Swap ->
            if List.length model.rows < 999 then
                model

            else
                let
                    a = at model.rows 1
                    b = at model.rows 998
                in
                { model
                    | rows =
                        model.rows
                            |> List.indexedMap
                                (\i r -> if i == 1 then b else if i == 998 then a else r)
                }

        Select id ->
            { model | selected = id }

        Remove id ->
            { model | rows = model.rows |> List.filter (\r -> r.id /= id) }

        -- Replace, Append, UpdateEvery10 and Clear are in the full file
```

It compiles clean, first try, against `master` at `4b29ac9`. Nothing in it is unusual beni. The
`Swap` arm is the whole of §10's argument: three walks and a rebuilt spine, and no way to write it
otherwise.
