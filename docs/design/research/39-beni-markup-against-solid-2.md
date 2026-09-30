# beni's compiled markup against Solid 2, end to end

**Commissioned by** `plans/browser-platform.md` §7's last markup slice: research 29's benchmark
app written in beni markup on `browser-tea`, compiled by beni, and measured with research 29's
harness against **Solid 2.0.0-rc.9 re-run in the same batch** and against the hand-written P2 —
per operation, on script medians, never a geometric mean (CLAUDE.md rule 8). Plus research 29's
static-heavy page and a helper-heavy twin of it, which decides whether more direct consumers pay
(the plan's MD18), and the app's output size against Solid 2's 22 163 brotli.

**What this is.** Measurements of what `beni build --platform=browser-tea` emits today (master
at `a99b860`), in headless Chromium, with the profiles and experiments that say why each lost
operation loses and what would fix it. **What this is not.** A decision: the owner's questions are
§7. Two small runtime defects found on the way were fixed in `a99b860` (§4.1); everything larger
is listed, priced by an experiment where one could be built.

**Read §0, then §7.**

---

## 0. Findings

### 0.1 The answer

**beni's markup beats Solid 2 on seven of the nine operations and ties or loses the other two;
it does not reach the "within 20 % of P2" bar on seven of nine.** Script medians, milliseconds, the
official throttling, one batch (§1), with the interquartile range and the sample count:

| operation | **beni** | beni `--release` | **Solid 2** | **P2** | vanillajs | beni ÷ Solid 2 | beni ÷ P2 |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1k | **4.95** [4.91–5.08] (15) | 4.92 [4.89–4.96] | 6.03 [5.99–6.13] | 4.05 [4.04–4.08] | 4.65 | **0.82** | 1.22 |
| replace 1k | **11.2** [11.1–11.2] (15) | 11.2 [11.1–11.2] | 13.3 [13.2–13.4] | 10.1 [10.0–10.2] | 9.60 | **0.84** | 1.11 |
| update every 10th | **1.70** [1.51–1.87] (15) | 1.69 [1.65–1.91] | 2.55 [2.30–2.70] | 0.98 [0.79–1.02] | 0.97 | **0.67** | 1.73 |
| select | **2.83** [2.74–2.99] (15) | 2.90 [2.68–2.98] | 3.22 [2.99–3.57] | 1.98 [1.73–2.13] | 1.33 | **0.88** | 1.43 |
| swap † | **1.96** [1.76–2.05] (20) | 1.96 [1.90–2.04] | 1.91 [1.76–1.99] | 0.79 [0.56–0.98] | 0.55 | **1.03** | 2.47 |
| remove † | **1.04** [1.01–1.05] (20) | 1.02 [1.01–1.06] | 0.95 [0.94–0.97] | 0.52 [0.51–0.52] | 0.53 | **1.09** | 2.02 |
| create 10k | **53.6** [53.3–53.9] (15) | 53.6 [53.5–54.2] | 67.1 [66.7–68.9] | 43.3 [42.9–43.5] | 47.7 | **0.80** | 1.24 |
| append 1k | **5.56** [5.50–5.67] (15) | 5.61 [5.57–5.71] | 6.52 [6.48–6.57] | 4.32 [4.29–4.35] | 4.88 | **0.85** | 1.29 |
| clear | **21.6** [21.3–21.8] (15) | 21.5 [20.2–22.0] | 24.3 [24.1–24.4] | 21.5 [21.0–22.0] | 21.3 | **0.89** | 1.01 |

† Re-run on their own at n = 20 (§1.3), because the main batch's cells were within their spread
(swap 1.84 against 1.72, remove 1.03 against 0.96 there); the vanillajs column of those two rows
is the main batch's.

- **Beats Solid 2**, outside the interquartile ranges: create 1k, replace 1k, update every 10th,
  select, create 10k, append 1k, clear.
- **Swap: a tie.** 1.96 against 1.91, the ranges overlapping (1.76–2.05 and 1.76–1.99). In the main
  batch it was 1.84 against 1.72, also overlapping.
- **Remove: a loss, 9 %.** 1.04 [1.01–1.05] against 0.95 [0.94–0.97]; the ranges do not touch, in
  either batch.
- **Within 20 % of P2**: replace 1k (1.11) and clear (1.01). Create 1k and create 10k are just over
  (1.22, 1.24); append 1.29; select 1.43; update 1.73; remove 2.02; swap 2.47.
- **`--release` changes nothing measurable.** Every release median is inside the development
  build's range. The release optimiser renames and prints compactly; it does not touch the
  runtime, which is where the time goes.

### 0.2 Why each one that misses loses, and what fixes it

| operation | where beni's extra time goes | the fix | priced by |
|---|---|---|---|
| select | the row's `rowClass model row` compiles `model.selected == Just row.id` to the derived `Maybe` equality with a fresh `Just` per row; each patched row also allocates its two handler messages and rewrites two `$$click` properties because a new message is never `===` the old | the compiler: `==` against a constructor application as a tag-and-field test; a handler hole whose value is a constructor over the item's fields skipped when the item is | `beni-eqmsg`: **2.83 → 2.02**, 0.63× Solid 2, **1.02× P2** (§4.2) |
| swap, remove | a render that moves rows rebuilds the key map: four hash operations and a `keyOf` call per row, where P2 does three | the runtime: keep the map, one lookup per surviving row and a stamp; duplicate keys need their rank chain kept, which is why it is not in `a99b860` | `beni-reuse`: swap **1.96 → 1.57** (0.82× Solid 2), remove **1.04 → 0.96** (1.01×) (§4.3) |
| swap, remove, update | the model half on `List`: `indexedMap` is four passes and 3 000 allocations, `filter` two, the swap's two lookups walk 998 cells each — 0.44–0.74 ms of the listener at 4× against P2's whole operation of 0.52–0.98 | an indexable sequence in `core/` (research 38, W35) | research 29 §10; not re-priced here |
| update every 10th | before `a99b860`, the same key-map rebuild on a render that moves nothing | **fixed**: `forKeyed` patches rows in place while every key is where it was | 2.45 (§3.1's batch) → **1.70** (§4.1) |
| clear | before `a99b860`, 1 000 rows removed one at a time | **fixed**: a list that is all its parent holds empties the parent at once | 25.5 (§3.1's batch) → **21.6** (§4.1) |
| create 1k/10k, append | mounting a row is three calls (`mountRow`, the row's `m`, the cloner) and a key-map insert, against P2's one function; the model half builds labels by walking three word lists | smaller: a row pair that registers its own key; `List`'s indexed read (above) | not priced |

### 0.3 The static-heavy page, and the helper-heavy verdict

Research 29's E1 — 2 053 elements, 50 text holes, one changed per message — written three ways in
beni and measured in the page (`performance.now()` around a click and the runtime's `flush`, no
paint), 5 pages × 20 samples × 100 messages:

| page | µs per message, 1× | 4× | mount, ms |
|---|--:|--:|--:|
| P2, by hand | 3.68 [3.45–4.05] | 14.1 [11.5–15.8] | 3.66 |
| **beni, one `view`** | **4.30** [3.95–5.11] | **17.3** [14.3–21.1] | 6.50 |
| Solid 2, inline | 6.80 [6.25–7.52] | 29.8 [26.7–33.5] | 6.47 |
| Solid 2, components | 7.67 [7.10–8.56] | 30.8 [28.2–37.4] | 8.13 |
| **beni, one component per section** | **7.02** [5.59–8.20] | **24.4** [20.8–32.9] | 5.08 |
| **beni, helper functions** | **30.3** [28.6–32.0] | **112** [109–118] | 4.51 |

**The inline page beats Solid 2 (0.63×) and is 1.17× P2. The helper-heavy page loses to Solid 2 by
4.5×.** Split into helpers — a section, its heading, each item and its paragraph a function whose
body is markup — every one of the 750 helper calls builds a block and every block is patched, each
render, although 749 of them hold the same values: 26 µs a message more than the same page inline.
**The same helpers behind one component per section cost 7.0 µs**, because a component whose props
are identical is not called (`language.md` §11.8) and its 15 blocks are never built. So the answer
to MD18 is **yes, more direct consumers pay, and the consumer that pays is the helper call in a
hole**; §6.3 says what the cheapest version is.

### 0.4 Size

Every JavaScript file the page loads, concatenated, brotli 11 (research 29 §12.1's method):

| | files | raw | brotli | minified brotli |
|---|--:|--:|--:|--:|
| beni, development | 12 | 47 922 | 12 997 | 5 840 |
| **beni, `--release`** | 12 | 38 232 | **11 697** | **5 739** |
| **Solid 2.0.0-rc.9** | 1 | 68 518 | **22 131** | 21 988 |
| P2 | 1 | 7 946 | 2 491 | 1 537 |

**beni's release build is 0.53× Solid 2's bytes as served and 0.26× minified.** Solid 2's figure
reproduces research 29's 22 163 to 32 bytes. Half of beni's 11 697 is the runtime file (6.3 kB
brotli on its own), which `--release` copies as written, comments and all; minified, the whole app
is 5 739 (§5).

---

## 1. Method

### 1.1 The harness

Research 29's harness did not survive — its §15 says every script stayed in a scratchpad, and that
scratchpad is gone. So it was rebuilt from its §1, in `bench/ui/`, and the ports are of the same
upstream files at the same commit (js-framework-benchmark `652198560d0c`):

| file | what it is |
|---|---|
| `lib/cdp.mjs` | the CDP client over Node's `WebSocket`: one Chromium with the official runner's flags, a fresh target per sample, real `Input.dispatchMouseEvent` clicks |
| `lib/trace.mjs` | the port of `webdriver-ts/src/timeline.ts`: `computeResultsCPU` (first `Commit` after the last of click, `FireAnimationFrame`, `TimerFire`, `Layout`, `FunctionCall`; the >16 ms rAF correction) and the script and paint interval unions |
| `lib/benchmarks.mjs` | the port of `benchmarksWebdriverCDP.ts`: the nine operations, their warm-ups and post-conditions, `benchmarksCommon.ts`'s throttling (4× update, select, swap, clear; 2× remove) |
| `bench.mjs`, `report.mjs` | the driver (rotation, GC before the trace, throttle, one click) and the tables |
| `verify.mjs` | every button of every subject, the DOM asserted after each — all subjects pass |
| `build.mjs` | beni dev and release, Solid 2 through Vite 8.3.0 + `@solidjs/vite-plugin` 3.0.0-next.35 + terser, the CSS and vanillajs fetched and checked by SHA-256 |
| `micro.mjs`, `gen-micro.mjs` | the static-heavy pages and their measurement |
| `profile.mjs`, `trace-dump.mjs`, `split.mjs` | a V8 profile of one operation cold or hot; one trace's events; the listener/render split |
| `experiments.mjs` | hand-edited copies of the build that price a fix (§4) |
| `results/` | every sample behind every table here |

Two deviations from research 29's harness, both deliberate: the trace is stopped a fixed settle
time after the click (500 ms, 4 s for create 10k) and the post-condition checked afterwards, so no
polling script lands inside the trace and moves "the last `FunctionCall`"; and the element's box is
found before tracing starts, so the trace holds the click and not the scroll.

**Validation.** vanillajs's size reproduces research 29's exactly (2 172 brotli), Solid 2's to 32
bytes; vanillajs is well ahead of P2 on select and swap and within about 10 % of it elsewhere, as
in research 29 §5.4; and P2 beats Solid 2 on all nine, at 0.38–0.88× its script, where research 29
§7.3 has 1.08–2.18× the other way up.

### 1.2 Subjects

- **beni**: `bench/ui/apps/beni/Main.beni`, 210 lines, `Tea.sandbox`. The model is research 29 §3's
  with `selected : Maybe Int` (idiomatic, and the reason §4.2 exists) and a Park–Miller seed,
  because a sandbox has no effects to draw random numbers from. The row is
  `<tr class={rowClass model row}>` inside `<For each={model.rows} keyed={.id}>`; the compiler
  gives it the input `[model.selected]` (MD31), so an edit that does not touch the selection skips
  every unchanged row. Built with `beni build --platform=browser-tea`, and again with `--release`.
- **Solid 2.0.0-rc.9**: research 29 §4.2's port, unchanged (`apps/solid2/src/bench.jsx`).
- **P2**: `apps/p2/bench.js`, **a reconstruction**: research 29 §7.1's listings verbatim, with the
  model, `update`, dispatch and the delegated `<tbody>` listener written back in from §4.3's
  description, since the file itself was lost. It behaves as research 29's did against Solid 2
  (§1.1), which is the only check available.
- **vanillajs**, from the benchmark repo, as the calibration subject.

### 1.3 Machine, load and noise

Chromium **153.0.8010.36** (nixpkgs, `--headless=new`), Node 24.19.0, Ryzen 9 5950X, Linux 6.12.110.
Chromium was pinned to CPUs 8–15 with `taskset`; the 1-minute load average at each benchmark's
start was 0.53–1.95 (the main batch), 0.58–0.92 (the re-run), 1.44 (the static page). Rotation as
research 29 §1.3: subject order shifted each iteration, a fresh target per sample.

**Absolute numbers are not research 29's.** Most script medians are 1.2–1.9× research 29's
(vanillajs create 1k 4.65 against 2.49, Solid 2 6.03 against 3.88, Solid 2 select 3.22 against
2.60), not uniformly (P2's update 0.98 against 1.08), and paint is about 1.8× (the eight pinned
cores share rasterisation with the main thread). Every comparison here is
therefore within one batch, which is research 29's own rule (i).

**Noise.** The main batch is n = 15; the two cells whose ranges overlapped were re-run at n = 20
(swap, remove) and the re-run is what §0.1 quotes. The throttle is the main noise source: at 4×
Chrome suspends the main thread in slices, so a short span of script can be stretched by a whole
slice — §3.2 shows a 0.07 ms listener inside a 0.6–1.0 ms trace event.

---

## 2. What beni emits for the row

The development build's row pair, abridged (`out/beni-dev/Main.mjs`):

```js
{ m: (item, position, cx) => { const cls = Main$rowClass(model, item); … const r = Main$t526(); …
                               r.setAttribute("class", cls); w55.data = item.id; w57.$$click = { $: "Select", a: item.id }; … },
  p: (i, item, position) => {
    const cls = Main$rowClass(model, item);
    const id = item.id, sel = { $: "Select", a: item.id }, label = item.label, rem = { $: "Remove", a: item.id };
    if (cls !== i.a0) { i.w0.setAttribute("class", cls); i.a0 = cls; }
    if (id !== i.a1) { … }  if (sel !== i.a2) { i.a2 = sel; i.w4.$$click = sel; }  …
  }, i: false, f: null }, [model.selected]
const Main$rowClass = (model, row) => Maybe$Maybe$$eq(Main$eq$prim, model.selected, { $: "Just", a: row.id }) ? "danger" : "";
```

Three things in it matter for §4: `rowClass` is a call to the derived `Maybe` equality with a
`Just` allocated for the comparison; the two handler messages are built on every patch, so their
`!==` is always true and both `$$click` properties are rewritten; and every value is computed
before any guard, so a row patched because the selection changed recomputes its label and id too.
The input array `[model.selected]` is right: `rowClass model row` reads one field of `model`, and
update, swap, remove and append skip every row whose item is unchanged.

## 3. The table, in detail

### 3.1 Before and after the runtime fix

`results/2026-09-29-table-before.json` is the same harness, n = 10, on the runtime before `a99b860`
(`beni`), with the in-place path alone (`exp-fast`) and with it and §4.2's edits (`exp-fast-both`):

| script, ms | update 10th | select | swap | remove | clear |
|---|--:|--:|--:|--:|--:|
| beni, before | 2.45 | 3.15 | 1.97 | 1.03 | 25.5 |
| beni, in-place path | 1.59 | 2.87 | 1.81 | 1.05 | 25.7 |
| Solid 2, same batch | 2.75 | 3.27 | 1.94 | 0.95 | 24.1 |

Before the fix beni lost clear (1.06×) as well; after it, clear is 0.89× (§0.1).

### 3.2 Where the script goes: listener and render

The trace separates the delegated listener — where the message is made and `update` runs — from
the microtask that renders (`split.mjs`, beni, 10 fresh pages each, medians):

| operation | script | listener (`update`) | render |
|---|--:|--:|--:|
| create 1k | 5.04 | 0.50 | 4.49 |
| update every 10th | 1.71 | 0.65 | 0.90 |
| select | 2.78 | 0.74 | 1.95 |
| swap | 2.01 | 0.71 | 1.28 |
| remove | 1.06 | 0.44 | 0.56 |
| append 1k | 5.69 | 0.59 | 5.04 |

The listener costs 0.44–0.74 ms at 4× on every operation, including select, whose `update` is one
record spread; a sampling profile of it on 30 fresh pages (`profile.mjs --cold --under=delegated`)
finds 0.07 ms of JavaScript per page — the listener walk, `queueMicrotask`, `update`. The rest is
the throttle's suspension slices landing in a short span (§1.3), so the listener's share is an
upper bound; what is real is the render column, and the listener's share of swap and remove, whose
`update`s walk the `List` (§4.4).

### 3.3 The table benchmark measures cold code

A single click after a few warm-ups runs most of the patch path for the first time: in the select
trace, V8 finalises baseline and Maglev compilations inside the render (`V8.FinalizeBaselineConcurrent
Compilation` 0.49 ms, `V8.BytecodeBudgetInterrupt` 0.59 ms). Hot, in a loop of 300 selects, the
numbers are unrecognisable: beni's select with §4.2's edits is **0.020 ms** a message at 4× and P2's
0.070. The benchmark rewards a patch path that is short in bytecode, few in functions, and light in
allocation before the optimising tiers arrive; §4's costs are all of that kind.

## 4. The losses, profiled

### 4.1 Fixed in `a99b860`: the key map on a render that moves nothing, and clear

`forKeyed` rebuilt its key map on every render that ran its rows — a new `Map`, and per row a
lookup, a delete, a duplicate check and an insert — even when the keys came back in the order they
left. P2 does the same, but beni's loop is longer, and update every 10th paid 1.7× P2 for it. The
new `inPlace` pass walks the list against the rows already there; while every key is the key of the
row at its position, and last render's keys were distinct (`s.d`), it patches only the rows whose
item or inputs changed and keeps the map. At the first key that differs it hands over to the full
pass, which is unchanged. Clear removed 1 000 rows one by one; a list that is all its parent holds
now empties the parent with `textContent = ""`, which is what Solid does. The black-box fixture is
`tests/corpus/browser/dom/KeyedInPlace` (a relabel, a new input value, a branch change inside the
in-place pass, duplicate keys on and off, a rotation, and both clears), run under happy-dom by the
gates and in Chromium by `test-browser`.

### 4.2 select: the equality and the handler messages

`profile.mjs --op=select` hot, before §4.1: `forKeyed` 41 %, `Main$rowClass` 15.6 %, the row's `p`
5.3 % plus `Maybe$Maybe$$eq` 2.1 % and the garbage collector 5.3 % for the three objects a patched
row allocates (`Just`, `Select`, `Remove`). `beni-eqmsg` is the development build with two edits a
compiler could make:

1. `model.selected == Just row.id` as `model.selected.$ === "Just" && model.selected.a === row.id`:
   an `==` whose one side is a constructor application tests the tag and the fields, allocating
   nothing and calling nothing. This is an emitter change (`src/js/`), for every `==` against a
   literal constructor, not a markup one.
2. The two handler holes neither rebuilt nor rewritten on a patch. In the dom lowering this is the
   split P2 makes by hand: values that read only the item are computed and guarded under one
   `item !== i.x` test, so a row patched because an input changed does not rebuild its messages.
   The lowering cannot do it today because `cx.rowValues` places all of a row's values at once
   without saying which read an input (`boundary.md` §9.4.3); the interface would need to say so.

Result: select **2.83 → 2.02** [1.94–2.30], 0.63× Solid 2 and 1.02× P2; nothing else moves.

### 4.3 swap and remove: the key map on a render that moves rows

When rows move, the full pass runs: per row a `keyOf` call, `byKey.get`, `byKey.delete` (or the
chain step for a duplicate), `map.get` for the duplicate check, `map.set`, and four property writes,
then `reconcile`. Hot, swap is 0.448 ms a message at 4× against P2's 0.070, and `forKeyed` is 33 %
of it. `beni-reuse` keeps the map across such a render instead: one `get` per surviving row, a
render stamp on the instance instead of the delete, `set` for new keys and `delete` for the rows
left unstamped. Swap **1.96 → 1.57** [1.34–1.77] (0.82× Solid 2), remove **1.04 → 0.96**
[0.95–0.98] (1.01×). It is not in `a99b860` because it assumes the new keys are distinct: the rank
chain that keeps duplicate keys rendering (`language.md` §11.9) has to be carried across, which is
a design, not a patch.

### 4.4 The model half: `List`

Swap's `update` looks up rows 1 and 998 by walking the list and rebuilds it with `indexedMap`, which
is `range`, `length`, `map2` and `reverse` — four passes and 3 000 cells; remove's `filter` is a fold
and a `reverse`. That is the 0.44–0.74 ms listener column where P2's whole remove is 0.52 ms. It is
research 29 §10's finding again, now inside a real app: the gap to P2 on swap and remove is the
`List` as much as the renderer, and an indexable `core/` sequence (research 38, W35) is the fix. It
also puts `Basics$add`, `Basics$sub` and `Basics$modBy` calls into the development build's loops.

### 4.5 create and append

Create 1k is 1.22× P2 and append 1.29×; the render is 4.5–5.0 ms of it. Mounting a row goes through
`mountRow`, the row pair's `m`, the template's cloner, four instance-field writes and a key-map
insert, against P2's one `makeRow`; the listener builds each label by walking three word lists with
`List.drop`. Neither was priced here; both are small, and neither is needed to beat Solid 2, which
beni does by 0.80–0.85× on these three.

## 5. Size

`sizes.mjs`, after `a99b860`. Release, file by file (brotli of each file alone):

| file | raw | brotli |
|---|--:|--:|
| `_platform/_browser/runtime.foreign.mjs` | 22 341 | 6 334 |
| `Main.mjs` | 5 222 | 1 942 |
| `_core/Basics.foreign.mjs` | 4 979 | 1 738 |
| `_core/List.foreign.mjs` | 2 991 | 1 198 |
| the other eight | 2 688 | 1 466 |

The runtime is copied whole and unminified, as `backend.md` §15.1 says siblings are; its comment
lines are 8 226 of its 22 341 raw bytes. Minified with terser, the app is 16 613 raw and **5 739 brotli**, 0.26×
Solid 2's minified bundle. The page is served as 12 ES modules; research 26 §8.2 is why a browser
build should ship one.

## 6. The static-heavy page and the helper-heavy page

### 6.1 The pages

`gen-micro.mjs` writes one page — 50 sections, each a heading with one text hole, a list of 12
items and a paragraph, 2 053 elements — as a single `view` (`Inline`), as helper functions
(`Helpers`: `section index value`, `heading index value`, `item label`, `para index`, all returning
`Html`), and as the same helpers behind one component per section (`Components`,
`<Card.section index={k} value={model.vk} />`). Solid 2 gets the inline page and a component version;
P2 gets one template and 50 guarded writes. Each message changes the next of the 50 values. The
pages render the same text (beni's 494 more characters are the inline starter script in its page).

### 6.2 Results

§0.3's table, with the first message after mount and a forced layout per message:

| page | first message, 1× / 4× ms | + forced layout, 1× / 4× ms |
|---|--:|--:|
| P2 | 0.320 / 1.260 | 0.078 / 0.316 |
| beni inline | 0.655 / 2.460 | 0.081 / 0.332 |
| Solid 2 inline | 0.775 / 3.085 | 0.095 / 0.387 |
| Solid 2 components | 0.815 / 3.315 | 0.097 / 0.397 |
| beni components | 0.880 / 3.215 | 0.087 / 0.356 |
| beni helpers | 0.870 / 3.350 | 0.109 / 0.435 |

The release builds are within the development builds' ranges on every column (`micro.log`).

### 6.3 What the helper-heavy page says about MD18

`backend.md` §15.4 compiles away one consumer, the `For` row; every other markup value is a block,
`{ t, v: [values] }`, placed with `childHtml`, which patches it when its kind is the slot's. On the
inline page there is one block, the root, and its `p` is 50 guarded writes: 4.3 µs, between P2 and
Solid 2. On the helper page a message builds 751 blocks and 751 value arrays and runs 751 `p`s,
each comparing values that did not change: 30 µs, 7× the inline page and 4.5× Solid 2, whose
components run once and cost nothing on update. **That is a page where beni loses to Solid 2, and
it is written the way Elm programmers write views.**

Components show where the cost can go. A component call whose props are all `===` their last value
is not made (§11.8), so 49 sections a message are skipped with their 750 blocks: 7.0 µs, 1.6× the
inline page and level with Solid 2 at 1×, ahead at 4× (24 against 31 µs). What remains over the
inline page is 50 prop records and their comparisons.

Two ways to get the helper page there, cheapest first:

1. **A helper call in a hole, skipped when its arguments are identical** — the component rule
   applied to any same-module function whose result is `Html` and whose call sits in a hole. It is
   the same evaluation relaxation `language.md` §11.11 already makes for components, rows and `Show`
   bodies, so it needs that section to say so (rule 1), and it would take the helper page to the
   component page's 7 µs.
2. **Helpers inlined into their caller's template** — research 36 §4.2's direct consumer: a call to
   a same-module function whose body is markup becomes part of the caller's template, so the page is
   the inline page, 4.3 µs, and the mount is one clone. It needs the lowering to see the callee's
   markup, which interface 1.0 does not give it.

Mount goes the other way (§0.3): the helper page mounts in 4.5 ms against the inline page's 6.5,
because the inline page's first clone parses one 2 000-element template string and the helper page
parses four small ones.

## 7. Questions for the owner

1. **MD18.** The helper-heavy page loses to Solid 2 by 4.5× per message (§6.3). Recommendation:
   skip a helper call in a hole whose arguments are all identical (§6.3, option 1), specified in
   `language.md` §11.11 beside the component rule, and keep inlining (option 2) for later.
2. **`==` against a constructor.** The idiomatic `model.selected == Just row.id` costs select a
   call, an allocation and the derived equality per row (§4.2). Recommendation: emit it as a tag and
   field test; it is an emitter change with no spec change.
3. **Row values that read only the item.** Recommendation: widen the lowering interface so a row's
   values say whether they read an input, and guard the item-only ones with one `item !== i.x`
   (§4.2, edit 2).
4. **The key map across moving renders.** Recommendation: build `beni-reuse`'s single-lookup pass
   properly, carrying duplicate keys' rank chains (§4.3); it takes swap from a tie to 0.82× Solid 2.
5. **The bar.** With 2–4 built, the priced experiments put beni ahead of Solid 2 on eight
   operations and level on remove (1.01×), and within 20 % of P2 on replace, select and clear; update, swap, remove, create and
   append stay over it, and the model half on `List` (§4.4) is most of what is left on swap and
   remove.

## 8. Could not determine

- Research 29's own P2 file: §1.2's is a reconstruction, validated only by how it compares with
  Solid 2.
- The listener's true cost under throttling (§3.2): the trace and the sampling profiler disagree by
  a factor of ten, and the throttle is the suspected cause, not a measured one.
- Unthrottled script medians: not run; research 29 §5.7 found the ordering unchanged there.
- Google Chrome as shipped: nixpkgs Chromium 153.0.8010.36 was used, research 29 used Chrome
  153.0.8010.47.

## 9. How to re-run

```sh
direnv exec . zig build -Doptimize=ReleaseSafe             # zig-out/bin/beni
direnv exec . node bench/ui/build.mjs                      # every subject, into bench/ui/out/
direnv exec . node bench/ui/experiments.mjs                # beni-eqmsg, beni-reuse (optional)
nix develop .#browser -c node bench/ui/verify.mjs
nix develop .#browser -c node bench/ui/bench.mjs --n=15 --taskset=8-15 --out=out/cpu.json \
    --subjects=beni,beni-release,solid2,p2,vanillajs,beni-eqmsg     # about 25 minutes
direnv exec . node bench/ui/report.mjs bench/ui/out/cpu.json
nix develop .#browser -c node bench/ui/micro.mjs --taskset=8-15    # about 2 minutes
direnv exec . node bench/ui/sizes.mjs
```

## 10. Addendum, 2026-09-29: the three fixes built

§7's questions 1–4 were answered by the project's manager on the owner's delegation and built, each
specified first: **a helper call in a hole skipped when its arguments are identical**
(`language.md` §6 and §11.6, §11.11; `backend.md` §15.3–§15.4; `boundary.md` §9.4 interface 1.1),
**`==` against a constructor as a tag and field test** (`backend.md` §4) with **a row's item-only
values left alone on an input-only patch** (`language.md` §11.11; `backend.md` §15.5; interface
1.2), and **the key map kept across a render that moves rows**, the duplicate-key rank chain
carried across (`backend.md` §15.5). Fixtures: `browser/dom/HelperSkip`, `emit/dom/DomHelpers`,
`run/EqAgainstConstructor`, `emit/EqAgainstConstructor`, `browser/dom/RowItemOnly`,
`emit/dom/DomRowItemOnly`, `browser/dom/KeyedMoves`.

### 10.1 The table

One batch, the same harness, machine and Chromium 153.0.8010.36 as §1, pinned to CPUs 8–15; 1-minute
load 0.60–1.77 at each benchmark's start; n = 15. `beni-before` is the build of `76a3a0e` (§0.1's
subject), re-run in the batch. `results/2026-09-29-table-after-fixes.json`. Script medians, ms:

| operation | **beni** | beni `--release` | beni-before | **Solid 2** | **P2** | beni ÷ Solid 2 | beni ÷ P2 |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1k | **5.04** [4.96–5.08] | 4.97 | 4.97 | 6.10 [6.02–6.21] | 4.08 [4.05–4.13] | **0.83** | 1.23 |
| replace 1k | **11.2** [11.1–11.3] | 11.2 | 11.2 | 13.3 [13.2–13.4] | 10.0 [10.0–10.1] | **0.84** | 1.12 |
| update every 10th | **1.77** [1.66–1.89] | 1.71 | 1.66 | 2.69 [2.32–2.75] | 0.89 [0.78–1.07] | **0.66** | 1.98 |
| select | **2.18** [2.05–2.63] | 2.09 | 2.96 | 3.11 [2.99–3.24] | 1.78 [1.64–1.93] | **0.70** | 1.22 |
| swap | **1.79** [1.71–1.97] | 1.80 | 1.96 | 1.86 [1.66–1.98] | 0.96 [0.81–1.18] | **0.96** | 1.87 |
| remove | **0.99** [0.98–1.01] | 0.98 | 1.05 | 0.95 [0.94–0.96] | 0.52 [0.51–0.52] | **1.04** | 1.92 |
| create 10k | **54.0** [53.3–54.0] | 53.4 | 53.9 | 67.3 [66.7–68.9] | 43.1 [42.9–43.3] | **0.80** | 1.25 |
| append 1k | **5.52** [5.50–5.63] | 5.54 | 5.57 | 6.53 [6.49–6.60] | 4.33 [4.29–4.35] | **0.85** | 1.27 |
| clear | **22.0** [19.6–22.2] | 22.0 | 21.9 | 24.1 [23.3–24.4] | 21.8 [21.5–22.0] | **0.92** | 1.01 |

- **Select** moved as priced: 2.96 → 2.18 in the batch (§4.2's experiment gave 2.02), 0.70× Solid 2,
  1.22× P2. Hot, the row's `p` no longer allocates or calls.
- **Remove** moved from 1.05 to 0.99 and **still loses to Solid 2**, by 4 %, the ranges not touching
  (0.98–1.01 against 0.94–0.96); §4.3's experiment priced 0.96. **Swap** is 1.79 against Solid 2's
  1.86, the ranges overlapping: still a tie. Separate batches at n = 20 (`results/2026-09-29-swap-
  remove-after.json`) put swap at 1.87–1.94 and the experiment's runtime at 1.73 in the same
  batch: swap's spread is 0.3–0.4 ms, the size of the effect. Hot, in a loop of 300 swaps at 4×
  (`profile.mjs`), the kept map is 0.08–0.14 ms a message against 0.47 before and 0.067 for the
  experiment, which assumed distinct keys and so skips the chain's field writes. What remains of
  both is §4.4's model half on `List`.
- **Nothing else moved** beyond its range; `--release` stays inside the development build's.
- **Beats Solid 2**, outside the ranges: seven of nine, as before (select now by 30 % rather than
  12 %); swap a tie; remove a loss. **Within 20 % of P2**: replace (1.12) and clear (1.01) only;
  select is 1.22.

### 10.2 The static-heavy page

`micro.mjs`, 5 pages × 20 samples × 100 messages, load 0.89 (`results/2026-09-29-static-page-after-
fixes.json`), µs per message, median [IQR]:

| page | 1× | 4× |
|---|--:|--:|
| P2 | 3.68 [3.50–4.11] | 13.9 [11.7–15.4] |
| beni, one `view` | 4.60 [4.19–5.47] | 19.4 [16.2–22.4] |
| **beni, helper functions** | **5.18** [4.79–6.96] | **20.3** [18.3–24.3] |
| beni, helpers, before | 29.5 [28.7–32.0] | 113 [110–118] |
| beni, one component per section | 6.22 [5.15–7.15] | 22.1 [19.8–26.7] |
| Solid 2, inline | 6.83 [6.35–7.70] | 30.3 [28.1–33.9] |
| Solid 2, components | 7.70 [7.13–8.50] | 31.2 [28.8–35.6] |

**The helper-heavy page went from 29.5 to 5.2 µs a message, 0.76× Solid 2's inline page and ahead of
the component page**; a render calls the one section whose value changed, and inside it the heading
whose argument did, and nothing else. Mount is unchanged (4.49 ms).

### 10.3 What this found

- **A nullary constructor of a type with fields is a fresh object every render**: `Run` in the
  benchmark's `view` is `{ $: "Run", a: null }`, built again each time, so `button "run" "…" Run`
  never has identical arguments and all six buttons' helpers are called on every render. Sharing one
  object per nullary constructor would let those calls be skipped; it is a representation change
  (`backend.md` §4) and was not made here. **Built the same day** (`backend.md` §4, *A nullary
  constructor is one object*): each module now writes one constant per such constructor, so the six
  button helpers are skipped after mount. Same harness, n = 15, CPUs 8–15, load 1.0–2.0,
  `results/2026-09-29-table-nullary-constants.json`, script medians against the unchanged compiler
  in the same batch: update every 10th 1.80 → **1.58** ms (0.57× Solid 2's 2.79), select 2.14 →
  2.11 (level; 0.65× Solid 2's 3.26). The helper-heavy page passes no nullary constructor and did
  not move (5.22 → 5.25 µs a message at 1×, `…static-page-nullary-constants.json`). Output size:
  `bench/size.mjs` gross over 229 programs, dev raw +0.04 % and brotli +0.09 %, `--release` raw
  −0.54 % and brotli +0.13 % (+291 bytes); `bench/corpus` under `--release` −651 raw, +117 brotli
  of 19 547 — a constant used once costs its definition and a name, where brotli already folded the
  repeated literal.
- The remaining losses are remove (1.04×) and a swap that ties; the key map is no longer where
  their time goes, `List` is (§4.4).

## 11. Addendum, 2026-09-30: Solid 1, and remove and swap taken apart

The owner's rule is that beni matches or beats Solid on every operation, and that where it does
not, what Solid does differently is found and adopted. §10 left remove a 4 % loss to Solid 2 and
swap a tie, and put the rest on the model half, `update` over `List` (§4.4). This section adds
**Solid 1.9.15** as a subject, checks that claim by timing the two halves apart, and builds the
renderer fix it points to. (§10.3's last bullet is corrected here: `List` was not where most of
the time went.)

### 11.1 Solid 1 as a subject

`bench/ui/apps/solid1/` is js-framework-benchmark's keyed `solid` entry at the harness's pinned
commit (`652198560d0c`): `src/main.jsx` verbatim, `rollup.config.js` unchanged but for the output
path. `solid-js` 1.9.15 (the latest 1.x on npm), `babel-preset-solid` 1.9.15 with
`omitNestedClosingTags` (its `babel-plugin-jsx-dom-expressions` is 0.40.10), Rollup 4.63.5,
node-resolve, terser with three passes, one IIFE. `build.mjs` builds it and the page loads it as a
classic script into `#main`; `verify.mjs` passes it on every button. Its app is Solid's own:
`createSelector` for the selection, a label signal per row, `toSpliced` for remove, an array swap.

### 11.2 The two halves, measured

`bench/ui/halves.mjs` takes one operation as the table benchmark meets it — a fresh page, the
benchmark's own warm-up, its throttle — and times it in the page: `performance.now()` around a
synthetic click on the target (beni's delegated listener and `update`; everything Solid 1 and P2
do; Solid 2's handler) and around the microtasks the click queued (beni's render, Solid 2's flush),
read by a microtask queued after the click returns. n = 20 fresh pages per cell, CPUs 8–15, load
2.6–3.6 (another session was running), medians [IQR], ms (`results/2026-09-30-halves.json`;
`beni-before` is §10's runtime, `beni-list` is §11.6's experiment):

| swap, 4× | click (update) | microtask (render) | both |
|---|--:|--:|--:|
| beni-before | 0.700 [0.436–0.984] | 1.313 [1.083–1.551] | 1.968 [1.833–2.145] |
| **beni** | 0.725 [0.371–0.929] | **0.938** [0.750–1.054] | **1.455** [1.234–1.914] |
| beni-list | 0.438 [0.095–0.737] | 0.815 [0.754–1.005] | 1.222 [1.088–1.406] |
| Solid 1 | 1.980 [1.756–2.198] | 0.047 | 2.103 [1.914–2.519] |
| Solid 2 | 0.550 [0.344–0.629] | 1.613 [1.326–1.755] | 2.108 [1.821–2.272] |
| P2 | 0.875 [0.761–1.015] | 0.043 | 1.045 [0.889–1.179] |

| remove, 2× | click (update) | microtask (render) | both |
|---|--:|--:|--:|
| beni-before | 0.160 [0.155–0.220] | 0.827 [0.608–0.855] | 1.000 [0.975–1.011] |
| **beni** | 0.155 [0.150–0.179] | **0.435** [0.430–0.445] | **0.595** [0.589–0.606] |
| beni-list | 0.090 [0.090–0.151] | 0.412 [0.361–0.421] | 0.510 [0.505–0.516] |
| Solid 1 | 0.588 [0.580–0.653] | 0.040 | 0.627 [0.624–0.696] |
| Solid 2 | 0.115 [0.110–0.121] | 0.867 [0.691–0.885] | 0.982 [0.873–1.005] |
| P2 | 0.545 [0.540–0.558] | 0.055 | 0.600 [0.590–0.648] |

**§4.4's attribution was wrong.** On §10's runtime the render, not `update`, was most of both
operations: remove 0.83 ms of render against 0.16 of `update`, swap 1.31 against 0.70. And the
render's time was not the DOM. `bench/ui/probe.mjs` builds a copy whose runtime stamps the seams of
a render; on §10's runtime (n = 20, load 2.0–2.6) remove's render was the key-map pass 0.40 ms, its
sweep 0.02 and the reconcile, DOM included, 0.12; swap's was the pass 0.49 and the reconcile 0.47.
§10's kept key map made that pass one lookup per row instead of four hash operations, but it still
visited every row of any render that moved one — a `keyOf` call, a `Map.get`, a stamp and five field
writes, a thousand times — in code the benchmark meets cold (§3.3).

### 11.3 What Solid does differently

Both Solids **match a list's ends before they build any map**. Solid 1's `mapArray`
(`solid-js/dist/solid.js`) and Solid 2's `updateKeyedMap` (`references/solid/packages/signals/src/
map.ts`) skip the common start of the old and new item arrays, then the common end, comparing items
by identity (Solid 2 also by its `keyed` function), and build `newIndices` only over what is left.
dom-expressions' `reconcileArrays` (udomdiff) does the same over nodes and finds two rows that
changed places at the ends of what is left in constant time. So Solid 1's remove never touches a
map — the 996-row end copied into `temp` and back, one owner disposed, one `removeChild` — and its
whole remove, `findIndex` and `toSpliced` included, is 0.63 ms against the 0.83 of beni's render
alone. Its swap does build a 998-entry `Map` in `mapArray` (the middle is rows 1–998), about 3 000
hash operations, which is why beni can beat it there once the pass is gone.

Solid 2 trims the same way, and its flush is still slower than Solid 1's whole operation (remove
0.87 against 0.63); where that goes was not profiled here.

### 11.4 The fix: the ends first

Built (`backend.md` §15.5, *Amended 2026-09-30*; `platforms/browser/runtime.js`, `trimmed`), with
`browser/dom/KeyedEnds` recorded on the runtime before it. When last render's keys were distinct,
`forKeyed` now matches in udomdiff's order: the start (patched in passing, as the old in-place pass
did), the end, and — what Solid does only in its DOM step — pairs of rows at the two ends that
changed places, again until none has. An item `===` its row's last item has that row's key, so its
key function is not called. Only the rows between the matched ends are looked up, and the
reconciler runs over that range alone. Remove is one walk to collect the items, one identity
comparison per row at the end, a position write per row and one drop; swap is the same with one
crossed pair and two moves, and no map operation at all. A key found twice hands the render to the
full pass, so duplicate keys still render by rank; the fixture's `copylast`, `copyfirst` and `twins`
steps pin that, and a runtime with the hand-over removed fails it, as does one that stops patching
rows whose position changed.

The fixture could not be red first: the change is behaviour-preserving by design, so its golden was
recorded on §10's runtime and passes unchanged on the new one; what makes it a guard is the two
mutations above, each of which fails it.

Render after the fix (§11.2's table): remove **0.83 → 0.435 ms**, swap **1.31 → 0.94**. The probe puts
remove's render at 0.12 for the ends, 0.05 for the row walk and 0.18 for the reconcile, now the one
`remove()` and the DOM's work around it; swap's is mostly the two `insertBefore`s.

### 11.5 The table, four frameworks

One batch, n = 15, CPUs 8–15, Chromium 153.0.8010.36, **1-minute load 1.7–3.5** at the benchmarks'
starts — higher than §10's, and every absolute number is about 15–25 % above §10's, so compare
within this table only (`results/2026-09-30-table-four-frameworks.json`). Script medians [IQR], ms:

| operation | **beni** | beni `--release` | beni-before | **Solid 2** | **Solid 1** | **P2** | beni ÷ S2 | beni ÷ S1 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| create 1k | 6.03 [5.29–6.36] | 5.50 | 5.49 | 6.57 [6.50–7.39] | 5.28 [5.21–6.07] | 4.30 [4.25–5.16] | 0.92 | 1.14 |
| replace 1k | 14.2 [13.0–14.8] | 13.2 | 12.8 | 15.9 [14.8–17.1] | 13.3 [13.0–15.1] | 11.2 [11.1–13.1] | 0.89 | 1.07 |
| update every 10th | 2.55 [2.18–2.75] | 2.45 | 2.49 | 3.74 [3.52–3.93] | 2.74 [2.58–2.79] | 1.51 [1.46–1.76] | 0.68 | 0.93 |
| select | 2.75 [2.54–3.09] | 2.57 | 2.74 | 3.96 [3.70–4.24] | **2.09** [1.88–2.40] | 2.55 [2.26–2.80] | 0.70 | **1.32** |
| swap | **1.93** [1.53–2.05] | 1.76 | 2.32 | 2.37 [2.24–2.68] | 2.24 [2.02–2.31] | 1.02 [0.81–1.20] | **0.82** | **0.86** |
| remove | **0.97** [0.72–1.01] | 0.95 | 1.21 | 1.35 [1.13–1.39] | 0.92 [0.90–0.96] | 0.82 [0.61–0.84] | **0.72** | 1.06 |
| create 10k | 63.5 [61.9–64.8] | 64.3 | 65.3 | 82.9 [80.5–84.3] | 68.3 [67.0–68.9] | 52.4 [51.1–52.9] | 0.77 | 0.93 |
| append 1k | 6.30 [5.78–6.71] | 6.54 | 6.76 | 7.99 [7.12–8.28] | 6.32 [5.64–6.61] | 5.04 [4.69–5.35] | 0.79 | 1.00 |
| clear | 28.5 [25.7–28.9] | 27.7 | 27.2 | 30.7 [29.8–32.2] | 28.6 [27.4–29.2] | 26.8 [26.6–27.8] | 0.93 | 1.00 |

Select, swap and remove again on their own, n = 20, load 1.8–4.4
(`results/2026-09-30-select-swap-remove.json`):

| operation | beni | beni-before | beni-list | Solid 2 | Solid 1 | P2 |
|---|--:|--:|--:|--:|--:|--:|
| select | 2.47 [2.27–2.91] | 2.48 | 2.54 | 3.90 [3.49–4.27] | **2.00** [1.88–2.09] | 2.14 [1.88–2.47] |
| swap | **1.70** [1.45–1.81] | 2.12 | 1.44 | 2.32 [2.20–2.65] | 1.89 [1.80–1.96] | 1.12 [1.01–1.17] |
| remove | 0.95 [0.89–1.00] | 1.35 | 0.63 | 1.09 [1.05–1.29] | 0.86 [0.68–0.91] | 0.72 [0.59–0.85] |

- **Against Solid 2, beni now has the lower median on all nine**, and swap (0.73–0.82×) and remove
  (0.72–0.87×) are wins outside the ranges in both batches for the first time.
- **Against Solid 1**: ahead on create 10k (0.93×, the ranges apart) and on swap (0.86–0.90×, the
  ranges just touching); level within the ranges on update, create 1k, replace, append, clear and
  remove, where beni's median is behind on create 1k (1.14×), replace (1.07×) and remove
  (1.06–1.10×); **behind on select, 1.23–1.32×, the ranges apart**. Solid 1 is the harder bar: its
  median beats Solid 2's on every operation here.
- In the page (§11.2) remove is 0.595 against Solid 1's 0.627 and swap 1.455 against 2.103; the trace
  also counts the delegated dispatch and beni's second task, which is the likeliest reason remove's
  trace median stays behind (not measured apart).
- `--release` stays inside the development build's ranges.

### 11.6 What remains

**Remove: the model half.** beni's render is now below Solid 1's whole operation; what is left is
`update`. The app's `List.filter model.rows (\row -> row.id /= id)` is the idiomatic `List` code and
is not written badly, but core's `filter` is a `foldl` and a `reverse`: two passes and about 2 000
cells to drop one row. `experiments.mjs`'s `beni-list` prices a `filter` that asks `isGood` once per
element, in order, and shares the tail after the last element it drops (with a one-pass
`indexedMap`): **remove 0.95 → 0.63** (0.73× Solid 1, 0.88× P2), `update` 0.155 → 0.090 ms in the
page. What it would take: `filter` and `indexedMap` rewritten in `core/List.beni` — both are beni,
not `foreign` — the tail-sharing `filter` as two tail-recursive walks, the first remembering the last
dropped position. It needs no `core/Array`, and nothing observable changes: `isGood` still runs once
per element, first to last. Not built here: the brief was not to rewrite core `List`.

**Swap: the model half, and it is `List`'s shape.** `swapRows` walks to rows 1 and 998 with
`List.drop` and rebuilds with `indexedMap` — reasonable `List` code. A one-pass `indexedMap` takes
the page's `update` from 0.73 to 0.44 ms, but a swap on a cons list rebuilds every cell before the
later index however it is written. Elm's own entry in js-framework-benchmark keeps its rows in an
`Array` and swaps with two `Array.get` and two `Array.set` (and removes with `Array.filter`); that is
the `core/Array` decision pending with the owner (research 38), and P2's 0.87 ms click, an array
swap, is what it stands for.

**Select against Solid 1: a structural loss, not a list one.** Solid 1's `createSelector` notifies
only the two rows whose selection changed; beni's row reads `model.selected` as an input, so a new
selection runs every row's `p` — a thousand calls, two of which write a class. §10's fixes made each
call cheap; the count is the gap. Matching Solid 1 here is research 29 §7.2's P3 *selector
recognition* (a row input compared against the row's own key), which `backend.md` §15.5 leaves as
later work.

**Size.** Solid 1 is 4 356 bytes brotli as served (4 354 minified); beni `--release` is 6 195 (5 568
minified): **1.42× Solid 1**, and 0.28× Solid 2's 22 131.

**Could not determine.** Why Solid 2's flush costs more than Solid 1's whole operation; and the
split of remove's trace time between the dispatch and the two tasks.

Re-run: `node bench/ui/build.mjs` and `node bench/ui/experiments.mjs`; then, under
`nix develop .#browser`, `node bench/ui/halves.mjs --taskset=8-15`, `node bench/ui/probe.mjs` followed
by `halves.mjs --subjects=beni-probe`, and `node bench/ui/bench.mjs --n=15 --taskset=8-15
--subjects=beni,beni-release,solid2,solid1,p2,vanillajs,beni-list`.

## 12. Addendum, 2026-09-30: select, and the selector recognised

§11.6 left select behind Solid 1 by 1.23–1.32×, the ranges apart, and named the cause: a new
selection ran the `p` of all thousand rows, because `model.selected` is a row input. This section
reads what Solid does, prices the fix, builds it, and measures it.

### 12.1 What Solid does

- **Solid 1.9.15**'s `createSelector(source)` (`solid-js/dist/solid.js`) keeps a `Map` from key to
  the `Set` of computations that asked `isSelected(key)`; every row registers one at mount (and an
  `onCleanup` to unregister). When `source` changes, 1.9 walks **every** entry of the map and marks
  stale the computations of the keys whose `fn(key, value)` answer changed — two rows' class
  effects run, but the walk visits all thousand keys. The js-framework-benchmark app writes
  `class={isSelected(rowId) ? "danger" : ""}`.
- **Solid 2.0.0-rc.9** has no `createSelector`; the port uses `createProjection`, a store written
  as `s[prev]` deleted and `s[id] = true`, so exactly two property signals notify
  (`apps/solid2/src/bench.jsx`).
- Both are written by the programmer. beni's row already has the key map Solid's selector builds:
  `forKeyed`'s own, from a key to its first row (§11.4). Research 29 §7.2 called the same thing
  P3's rung 4: "maintain the key→instance index it already has for reconciliation".

### 12.2 The design

No syntax and no change to what `view` means (`language.md` §11.9, §11.11, *amended 2026-09-30*;
`backend.md` §15.5; `boundary.md` §9.4.6 interface 1.3). The compiler recognises a **selector**: a
keyed row's input that every read in the row — directly, or through the same-module functions it
is passed to, as the row's inputs are already followed — compares with `==` or `/=` against the
row's list key written through the item, or `Just` of it, where the comparison is `===` or
`backend.md` §4's tag and field test. `rowClass model row` qualifies. It hands the lowering the
input's position and a **probe**, `s.$ === "Just" ? s.a : s`: the one key the comparison can hold
for, or an object, which no key is. `dom` writes both on the row object (`g`, `z`); `forKeyed` keeps
last render's probe and, when the probe is all that changed, patches the rows of the old probe's
key and the new one's from its key map and visits no other row. With an edit in the same render,
a row whose item and other inputs did not change is patched only if its key is one of the two
probes. A row the compiler does not recognise behaves as before. Near misses — a key that is not
the list key, the input also read another way, a `let`, a position-keyed list, another module's
function — are pinned as not recognised by `emit/dom/DomSelectorNearMiss`; behaviour by
`browser/dom/Selector` (selection moving, the same id twice, an id no row has, none, duplicate
keys, a selection and an edit in one render, the selected row removed, reference keying with
`/=`), whose `Debug.log` in the class shows which rows run. Red first: against the runtime before
this change it logs every row on each selection and fails.

**Priced before it was built** (`halves.mjs`, n = 20, CPUs 8–15, load 0.67), a hand-edited copy of
the development build with the new runtime and `g`/`z` written in: select's render microtask
1.197 → **0.550** ms, the whole in-page select 1.702 → **1.040**, against Solid 1's 1.632.

### 12.3 The table

One batch, n = 15, CPUs 8–15, Chromium 153.0.8010.36, **1-minute load 2.1–17.8** at the
benchmarks' starts (other sessions were running; 15.7 at remove and 17.8 at clear) —
`results/2026-09-30-table-selector.json`. `beni-before` is the same build with the row object's
`g` and `z` removed and the runtime before this change, which is exactly the previous compiler's
output. Script medians [IQR], ms:

| operation | **beni** | beni `--release` | beni-before | **Solid 2** | **Solid 1** | **P2** | beni ÷ S1 |
|---|--:|--:|--:|--:|--:|--:|--:|
| create 1k | 5.21 [5.03–5.65] | 5.05 | 5.07 | 6.18 [6.13–6.23] | 5.06 [5.00–5.18] | 4.13 | 1.03 |
| replace 1k | 13.5 [12.4–13.8] | 13.6 | 13.6 | 15.6 [15.1–15.8] | 13.8 [13.1–14.3] | 11.9 | 0.98 |
| update every 10th | 2.08 [1.87–2.18] | 2.01 | 2.02 | 2.71 [2.52–2.88] | 1.88 [1.71–2.23] | 1.09 | 1.10 |
| **select** | **1.74** [1.46–1.87] | **1.56** [1.49–1.72] | 2.52 [2.23–2.88] | 3.58 [3.26–3.84] | 2.03 [1.84–2.28] | 2.11 [2.00–2.65] | **0.86** |
| swap | 1.81 [1.61–1.95] | 1.74 | 1.77 | 2.45 [2.04–2.84] | 2.09 [1.91–2.51] | 1.07 | 0.86 |
| remove | 0.99 [0.95–1.03] | 0.94 | 0.97 | 1.12 [1.09–1.40] | 0.88 [0.65–0.96] | 0.81 | 1.12 |
| create 10k | 65.8 [62.3–69.3] | 64.5 | 64.4 | 83.2 [81.0–88.2] | 67.8 [65.9–69.4] | 53.5 | 0.97 |
| append 1k | 6.93 [6.75–8.81] | 6.63 | 6.72 | 8.57 [8.20–12.7] | 6.71 [6.49–10.2] | 5.61 | 1.03 |
| clear | 31.8 [30.2–40.3] | 37.1 | 33.6 | 39.2 [36.4–43.7] | 36.5 [31.9–41.7] | 34.8 | 0.87 |

Select again on its own, n = 20, load 7.7 (`results/2026-09-30-select-selector.json`): beni
**2.30** [2.08–2.45], `--release` 1.96 [1.81–2.26], beni-before 3.34 [3.10–3.54], Solid 2 5.12
[4.90–5.37], **Solid 1 2.60** [2.48–2.87], P2 2.93 [2.78–3.04] — every absolute number is higher
under the load, the order is the same, and beni's range and Solid 1's are apart.

In the page (`halves.mjs`, n = 20, load 6.9, `results/2026-09-30-halves-select.json`): beni's
render microtask **1.797 → 0.942** ms, its whole select 2.505 → **1.483** against Solid 1's 2.290
and P2's 2.467.

- **Select now beats Solid 1**: 0.86× in the batch (1.74 against 2.03, the ranges touching at
  1.84–1.87), 0.88× on its own with the ranges apart; `--release` 0.77×. Against Solid 2 it is
  0.45–0.49×, and it is ahead of P2, whose select walks every row (0.82×).
- **Nothing else moved**: every other beni median is within beni-before's range. Create 1k, the
  operation that mounts every row's object, is 5.21 against 5.07, inside both ranges.
- **Against Solid 1**, what the batch still puts behind it: remove (1.12×, ranges apart; §11.6's
  model half, not built) and update every 10th (1.10×, ranges overlapping). Level within the
  ranges on create 1k, replace, append, create 10k and clear (clear's lower median under a load
  of 17.8 is not a claim); ahead on select and swap (0.86×, the ranges just touching).

### 12.4 The static-heavy pages

`micro.mjs`, 5 pages × 20 samples × 100 messages, load 5.7, against the same pages on the runtime
before this change (`results/2026-09-30-static-page-selector.json`); they have no list, and the
change reaches them only through the slot's extra field. µs per message, 1× / 4×: one `view`
5.85 / 23.0 against 6.08 / 23.5 before; helper functions 6.30 / 24.8 against 7.30 / 24.9 before;
Solid 2 inline 9.22 / 37.0, P2 5.25 / 17.1. **No regression.**

### 12.5 Re-run

`node bench/ui/build.mjs`; then, under `nix develop .#browser`, `node bench/ui/bench.mjs --n=15
--taskset=8-15 --subjects=beni,beni-release,solid2,solid1,p2`, `node bench/ui/bench.mjs --n=20
--benchmarks=04_select1k …`, `node bench/ui/halves.mjs --benchmarks=04_select1k` and `node
bench/ui/micro.mjs`. `beni-before` is not rebuilt by the scripts: it was the development build
with `, g: 0, z: …` removed from `Main.mjs` and the previous `runtime.js` copied in, registered in
`out/extra-subjects.json`.

## 13. Addendum, 2026-09-30: create, replace and update taken apart, and the model half priced

§12.3 left beni behind Solid 1 on *update every 10th* (1.10×, the ranges overlapping) and *remove*
(1.12×, the ranges apart), and §11.5 had *create 1k* and *replace 1k* medians 1.07–1.14× behind.
The owner's rule is to find what Solid does differently and adopt it. This section times the two
halves of each (§11.2's `halves.mjs`), reads Solid 1's code for each, builds the three renderer
changes that measured, and prices the model half on `List` without changing core.

### 13.1 The halves, before

`halves.mjs`, n = 20 fresh pages per cell, CPUs 8–15, medians [IQR], ms. Create and replace ran
under load 3.0–17 from other sessions and update under 6.4, so compare within a table only
(`results/2026-09-30-halves-before.json`, `…-halves-model.json`). `beni-before` is the session's
starting build.

| operation | subject | click (update) | microtask (render) | both |
|---|---|--:|--:|--:|
| create 1k, 1× | beni-before | 0.550 | 5.060 | 5.600 [5.344–5.729] |
| | Solid 1 | 5.480 | 0.040 | 5.518 [5.226–5.758] |
| replace 1k, 1× | beni-before | 0.548 | 11.055 | 11.567 [11.284–13.552] |
| | Solid 1 | 11.397 | 0.045 | 11.438 [11.292–13.243] |
| update every 10th, 4× | beni-before | 0.540 [0.135–0.760] | 1.063 | 1.480 [1.400–1.721] |
| | Solid 1 | 1.493 | 0.035 | 1.657 [1.514–1.843] |
| remove, 2× | beni-before | 0.373 [0.285–0.386] | 0.147 | 0.517 [0.505–0.536] |
| | Solid 1 | 0.527 | 0.040 | 0.570 [0.550–0.716] |

**In the page beni was already level or ahead on all four**; what the trace table adds is the
dispatch around the click, the second task and the garbage collections an operation's allocation
triggers, and those land differently per sample (a GC scavenge moves between the two halves, which
is why the click column's ranges are bimodal). `probe.mjs` (updated here for the selector's
`trimmed` signature) put create's render at 4.41 ms of mounting rows (the full pass) and 1.51 of
moving them into the page; replace's at 4.0 ms of mounting and **8.8 ms of reconcile**, removing
the thousand old rows one by one and inserting the new ones; update's at 0.75 ms of the start walk,
100 row patches in it.

### 13.2 What Solid 1 does, and where beni spent more

Read in `solid-js` 1.9.15 (`web/dist/web.js`, `dist/solid.js`) and the row the benchmark's JSX
compiles to (babel-preset-solid, the harness's own build):

- **The row is one template clone and one render effect.** `_el$10.textContent = rowId` and the two
  click handlers (closures over `rowId`, never rewritten) are set once; `createRenderEffect` then
  writes the class (`className`) and the label (`.data`), comparing each with the last value it
  kept, **and its first run is the mount**. So the function an edit runs has run once per row
  before the first edit. beni's row had two functions, `m` and `p`, and a thousand mounts ran only
  `m`: *update every 10th*, after a warm-up of three updates, met a `p` that had run 300 times.
  Warm, the difference is the other way: `profile.mjs --op=update`, 200 updates in one page at 4×,
  is **0.860 ms per update for beni and 0.965 for Solid 1**, with beni's `p` and Solid's effect
  each about 40 % of the samples.
- **Create**: `mapArray`'s path for a list that was empty maps every item with no `Map`
  (`solid.js`, *len === 0*), and `insertExpression` hands the rows to `appendNodes`, one
  `insertBefore` per row straight into the `tbody` (`web.js:591–597`, `:637`). beni built a
  `DocumentFragment`, moved every row into it, then moved the fragment: every node was inserted
  twice. beni also records each key in its key map, which Solid does not do here (it builds a
  `createSelector` entry per row instead).
- **Replace**: the same as beni. `mapArray` finds no common end, and `reconcileArrays` (`web.js:135`)
  removes each of the thousand old rows with `remove()` and inserts each new one. Neither empties
  the `tbody` at once, which a clear does in both.
- **Update**: `batch` over a hundred `setLabel`s, then a hundred effects, each one `.data` write.
  beni's render walks the thousand rows' start (§11.4) and patches the hundred whose item changed:
  a class comparison, the label's `.data`, and two handler messages rebuilt and written, since
  `Select row.id` is a new object whenever the item is.
- **Remove**: `toSpliced` on an array and one row disposed; §11.3 has the rest.

### 13.3 What was built

Specified first in `backend.md` §15.5 (three *amended 2026-09-30* paragraphs).

1. **A replacement empties the parent** (`runtime.js`, `trimmed`). When the ends match nothing, no
   two rows changed places at them, no key is found in the key map, and the rows are all their
   parent holds, the parent is emptied with one `textContent = ""` and the new rows appended. This
   is not what Solid does; it is what Solid's clear does, and it is beni's own clear. Otherwise
   the reconciler runs as before. `browser/dom/KeyedReplace` was recorded on the runtime before
   the change and fails against three mutations: emptying the parent when a row is kept, when two
   rows changed places at the ends (the row between them loses the focus), or when the parent
   holds other children.
2. **A list mounted where none was goes straight into the page**, row by row before the slot's
   marker, as `appendNodes` does. The probe's insert step fell 1.51 → 1.05 ms.
3. **A row mounts through its patch** (`dom.zig`, `mountsThroughPatch`; `runtime.js`, `mountRow`):
   where `p`'s guarded writes are exactly what `m` writes — text placeholders, style entries,
   events, attributes that are not constant, `raw`, class or style lists or `stateful` — and `p`
   evaluates the values and writes them in the order `m` did (the item-only ones after the
   others), `m` clones, walks and sets only an event's extractor, flags, listener and mount
   context, returns the instance with every kept value `undefined`, and the row says `w: true`;
   `mountRow` calls `p` on it. The benchmark's row qualifies. `emit/dom/DomRowMount` pins the shape
   and two rows that keep their own `m` (an item-only value first; a class toggle);
   `browser/dom/RowMountOrder`, recorded before, pins with `Debug.log` that values evaluate in
   source order at mount and that an input-only patch still leaves item-only values alone, and
   fails when the order checks are removed. Three `emit/dom` goldens changed shape
   (`DomRowItemOnly`, `DomSelector`, `DomSelectorNearMiss`); no behaviour fixture moved.

**Priced and not built** (`results/2026-09-30-renderer-experiments.json`, the table harness, n = 15,
load 2.0–4.4, hand-edited copies of the development build):

| subject | create 1k | replace 1k | update every 10th |
|---|--:|--:|--:|
| beni (session start) | 5.80 [5.11–5.88] | 11.8 [11.6–12.2] | 2.12 [1.89–2.41] |
| the runtime's seven row fields in `m`'s object literal | 5.76 | 11.6 | 1.97 |
| rows straight into the page (built, item 2) | **5.49** [5.14–5.70] | 11.6 | 2.24 |
| replacement empties the parent (built, item 1) | 5.88 | **10.6** [10.5–10.8] | 2.31 |
| handler messages compared by field, not identity | 5.84 | 11.7 | 2.20 |
| Solid 1 | 5.75 [5.63–5.88] | 11.9 [11.8–13.1] | 2.01 [1.78–2.26] |

Neither the literal (no hidden-class growth after `m`) nor skipping the two handler rewrites moved
any operation beyond its range, so neither was built; update's spread in that batch was ±0.3 ms.
Item 3 was priced the same way (`…-row-mount-priced.json`, n = 20, load 1.9–2.5): update 2.20 →
**1.95**, select 1.74 → **1.52** (the selector's two rows run `p` too), create 5.25 → 5.24.

### 13.4 The model half

The click column is `update` plus the delegated dispatch. **Create** spends 0.54 ms there
(`buildFrom` and three `pick`s per row, each a `List.drop`, a `Just` and a `withDefault`), against a
4.1 ms render. **Update's** `List.indexedMap` is `length`, `range`, `map2Help` and `reverse`: four
walks and about 3 000 cells for a thousand rows. **Remove's** `List.filter` is `foldl` and `reverse`.
Two hand-edited copies of the build price core rewritten, core untouched (`experiments.mjs`):
`beni-cons`, `filter` and `indexedMap` written in beni as cons steps and compiled to the loop
`backend.md` §8's *tail calls modulo cons* emits (copied from a build of that source: one pass, n
cells, no `reverse`); and `beni-list`, §11.6's tail-sharing `filter` and one-pass `indexedMap`.

In the page (`results/2026-09-30-halves-final.json`, the final build, n = 20, load 1.2–2.0), the
whole operation, since the collections move between the halves:

| operation | beni | beni-cons | beni-list | Solid 1 | P2 |
|---|--:|--:|--:|--:|--:|
| create 1k, 1× | **4.640** [4.595–4.684] | 4.645 | 4.655 | 4.868 [4.821–4.926] | 3.998 |
| update every 10th, 4× | 1.320 [1.140–1.454] | **1.155** [1.057–1.405] | 1.125 | 1.528 [1.304–1.807] | 0.985 |
| remove, 2× | 0.517 [0.510–0.531] | **0.455** [0.450–0.460] | 0.448 | 0.570 [0.559–0.598] | 0.540 |

In the table harness (`…-model-half.json`, n = 20, load 0.9–2.0), script medians [IQR]:

| operation | beni | `--release` | beni-cons | beni-list | Solid 1 | Solid 2 | P2 |
|---|--:|--:|--:|--:|--:|--:|--:|
| update every 10th | 1.89 [1.61–2.01] | 1.57 | **1.52** [1.44–1.72] | 1.66 | 1.68 [1.49–1.95] | 2.63 | 1.05 |
| swap | 1.50 [1.36–1.69] | 1.40 | 1.27 | 1.22 | 1.91 [1.49–1.99] | 1.87 | 0.91 |
| remove | 0.61 [0.59–0.76] | 0.57 | **0.54** [0.52–0.66] | 0.54 | 0.57 [0.56–0.69] | 0.95 | 0.52 |

- **Remove's gap is the model half, as §11.6 said**: the render is 0.15 ms against Solid 1's
  whole 0.57, and a direct-building `filter` — the plain `x :: filter rest isGood` that the
  compiler already turns into a loop — takes remove from 0.61 to **0.54, 0.95× Solid 1**, and in the
  page 0.517 → 0.455. Sharing the tail after the last dropped element (`beni-list`) buys nothing
  more measurable here (0.54, 0.448 in the page).
- **Update's model half** is 0.17 ms in the page at 4×; with a one-pass `indexedMap` the table
  median is 1.52, 0.91× Solid 1.
- These are core's to change (`backend.md` §8 already measured core's accumulator-and-`reverse`
  functions 2.4–7× slower than their cons-step versions), not built here; and the decision pending
  on replacing `List` with an array-backed sequence (report 38 §17) would change them anyway —
  Elm's own benchmark entry removes with `Array.filter` and swaps with two `Array.set`s.

### 13.5 The table

One batch, the final build, n = 15, CPUs 8–15, Chromium 153.0.8010.36, 1-minute load 1.1–2.7 at
each benchmark's start except swap (8.5) and remove (8.9), when another session ran
(`results/2026-09-30-table-row-mount.json`). `beni-before` is the session's starting build, re-run in
the batch. Script medians [IQR], ms:

| operation | **beni** | `--release` | beni-before | **Solid 2** | **Solid 1** | **P2** | ÷ S1 | ÷ S2 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| create 1k | **4.81** [4.78–4.89] | 4.75 | 5.04 | 6.05 [6.04–6.13] | 4.94 [4.91–4.99] | 4.07 | **0.97** | 0.79 |
| replace 1k | **10.5** [10.4–10.6] | 10.5 | 11.5 | 13.3 [13.1–13.5] | 11.7 [11.7–11.8] | 10.1 | **0.90** | 0.79 |
| update every 10th | **1.71** [1.57–1.88] | 1.83 | 1.97 | 2.71 [2.55–2.79] | 1.76 [1.70–1.91] | 1.06 | **0.97** | 0.63 |
| select | 1.51 [1.33–1.73] | 1.41 | 1.83 | 3.51 [3.03–4.10] | 1.72 [1.53–1.96] | 1.92 | 0.88 | 0.43 |
| swap | 1.41 [1.25–1.63] | 1.23 | 1.29 | 1.96 [1.76–2.03] | 1.40 [1.28–1.75] | 0.97 | 1.01 | 0.72 |
| remove | 0.77 [0.65–0.85] | 0.58 | 0.66 | 0.95 [0.94–0.97] | 0.57 [0.56–0.57] | 0.53 | 1.36 | 0.81 |
| create 10k | 51.7 [51.3–51.9] | 51.5 | 54.1 | 68.5 [67.2–69.3] | 55.3 [54.9–56.1] | 43.3 | 0.93 | 0.75 |
| append 1k | 5.32 [5.30–5.36] | 5.27 | 5.41 | 6.55 [6.52–6.62] | 5.20 [5.18–5.29] | 4.31 | 1.02 | 0.81 |
| clear | 22.2 [19.7–22.3] | 22.1 | 22.4 | 24.2 [23.8–24.3] | 22.8 [22.7–23.2] | 21.7 | 0.97 | 0.92 |

- **Against Solid 1**: create 1k is 0.97× with the ranges apart (5.04 before), replace **0.90×**
  apart (11.5 before, 0.98×), create 10k 0.93× apart. Update every 10th is 0.97× with the ranges
  overlapping (1.97 before); §13.4's separate batch had it at 1.12×, also overlapping — **level**,
  and ahead once the model half is one pass. Select 0.88×, clear 0.97× and append 1.02× within
  the ranges. Swap is level (1.01×) and 0.78× in the calmer §13.4 batch, where it was 1.50 against
  1.91. **Remove is behind**: 1.36× here under load 8.9 and 1.06× in §13.4's batch (0.61 against
  0.57, the ranges overlapping); `--release` is 1.01–1.03×. What remains of it is §13.4's model half.
- **Against Solid 2: beni is ahead on all nine**, from 0.43× (select) to 0.92× (clear), the ranges
  apart on every one.
- **Against P2**: within 5 % on replace and clear; ahead on select.
- Between the two slices (`…-table-replace.json`, load 0.7–1.6, after items 1–2 only): create 4.79
  against Solid 1's 4.95, replace 10.6 against 11.9, the other seven within their ranges of this
  table's.

**Size.** The benchmark app's `--release` build is 5 345 bytes brotli as served (Solid 1: 4 356);
a row that mounts through its patch writes its values once, in `p`, instead of in both functions.

**Could not determine.** Why the trace puts update behind Solid 1 in some batches when the page
never does (§13.1): the dispatch, the second task and where a scavenge lands were not separated.

### 13.6 Re-run

`node bench/ui/build.mjs` and `node bench/ui/experiments.mjs` (`beni-cons`, `beni-list`); then,
under `nix develop .#browser`, `node bench/ui/halves.mjs --taskset=8-15
--benchmarks=01_run1k,02_replace1k,03_update10th1k_x16,06_remove-one-1k
--subjects=beni,beni-cons,beni-list,solid1,solid2,p2`, `node bench/ui/probe.mjs` and the same with
`--subjects=beni-probe`, `node bench/ui/bench.mjs --n=15 --taskset=8-15
--subjects=beni,beni-release,solid2,solid1,p2`, and `node bench/ui/profile.mjs --subject=beni
--op=update` for the warm figure. `beni-before` was the build of `95312a62` kept in
`out/beni-before/` and registered in `out/extra-subjects.json`; the renderer experiments of §13.3
were hand edits of `out/beni-dev/` and are not scripted.
