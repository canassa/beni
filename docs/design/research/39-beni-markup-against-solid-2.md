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
